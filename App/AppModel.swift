//
//  AppModel.swift
//  MacBridge (app) · MacBridge
//
//  Owns the bridge, permissions, client setup, restart and diagnostics.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import EventKit
import Foundation
import MCP
import MacBridgeKit
import SwiftUI

/// Owns the bridge server and everything the menu displays.
///
/// The app is the only process that touches EventKit, which is what makes a single
/// TCC grant against MacBridge.app cover every AI client.
@MainActor
final class AppModel: ObservableObject {

    /// Whether the bridge socket is up, for the panel's status line.
    enum ServerState: Equatable {
        case stopped
        case listening(path: String)
        case failed(String)

        var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var permissions: [EventKitDomain: EKAuthorizationStatus] = [:]
    @Published private(set) var clientSetup: [ClientSetup] = []
    /// The outcome of the last Connect button, shown under that client's row.
    @Published private(set) var setupResult: SetupResult?
    /// The client a Connect is running for, so its button can show progress.
    @Published private(set) var connectingClientID: String?
    /// Whether macOS opens MacBridge at login, as last read from the system.
    @Published private(set) var launchAtLogin: LaunchAtLogin.Status = .disabled
    /// Why the last change to ``launchAtLogin`` failed, shown under the checkbox.
    @Published private(set) var launchAtLoginError: String?
    @Published var log = ActivityLog()
    /// What clients may do: Read-only, and asking before deleting. Saved on change,
    /// where `macbridge mcp --direct` reads it too.
    @Published var policy = AccessPolicy.load() {
        didSet {
            guard policy != oldValue else { return }
            policy.save()
            BridgeLog.info(
                "policy: read-only \(policy.readOnly ? "on" : "off"), "
                    + "ask before deleting \(policy.confirmDestructive ? "on" : "off")",
                category: .app
            )
        }
    }
    /// The animated traffic in the menu-bar icon and the panel. Not `@Published`:
    /// it ticks at 30fps while busy, and only the views drawing it should redraw.
    let traffic = BridgeTraffic()

    private let registry = ToolRegistry()
    private var server: BridgeServer?
    /// The last confirmation asked for, so the next waits for it: two deletes
    /// arriving together get two alerts in turn rather than one on top of the other.
    private var confirmationTail: Task<Void, Never>?

    /// One store, used only for permission checks and requests. The services in
    /// MacBridgeKit hold their own.
    private let permissionStore = EKEventStore()

    /// Reads permissions and client setup; the server waits for ``start()``.
    init() {
        refreshPermissions()
        refreshClientSetup()
        refreshLaunchAtLogin()
    }

    /// Re-read the client config files. Cheap, and they change outside the app —
    /// someone runs `claude mcp add` in a terminal and expects the panel to notice.
    func refreshClientSetup() {
        clientSetup = ClientSetup.detect(shimPath: shimPath)
    }

    /// True when at least one client is pointed at this app.
    var hasConfiguredClient: Bool {
        clientSetup.contains { $0.isReady }
    }

    /// Where the `claude` CLI is, if installed — the `claude mcp add` route needs it.
    var claudeCLIPath: String? { ClientSetup.claudeCLIPath() }

    // MARK: Server lifecycle

    /// Start serving on this bundle's socket. A no-op when already running; a
    /// failure is shown in the panel and logged rather than thrown.
    func start() {
        guard server == nil else { return }

        do {
            let socketURL = try BridgeProtocol.socketURL()
            let server = BridgeServer(
                registry: registry,
                socketURL: socketURL,
                authorize: { [weak self] request, identity in
                    // Fail closed: a policy check that can't run must not allow.
                    guard let self, let tool = request.name else { return AccessPolicy.unavailable }
                    return await self.authorize(tool: tool, arguments: request.arguments, client: identity)
                },
                observe: { [weak self] event in
                    // Observer is called from the server's connection queues.
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
            )
            try server.start()
            self.server = server
            state = .listening(path: socketURL.path)
            BridgeLog.info(
                "MacBridge \(MacBridge.version) started from \(Bundle.main.bundlePath)",
                category: .app
            )
        } catch {
            state = .failed(error.localizedDescription)
            BridgeLog.error("could not start the bridge: \(error.localizedDescription)", category: .app)
        }
    }

    // MARK: Access policy

    /// Apply ``policy`` to one call: nil to run it, or the refusal the model sees.
    private func authorize(tool: String, arguments: [String: Value]?, client: ClientIdentity) async -> String? {
        switch policy.decision(for: tool) {
        case .allow:
            return nil
        case .refuse(let message):
            BridgeLog.info("\(tool) refused — read-only mode", category: .tools)
            return message
        case .confirm:
            let deadline = Date().addingTimeInterval(ConfirmationPrompt.budget)
            let target = await registry.confirmationTarget(tool, arguments: arguments)
            switch await confirm(client: client.name, tool: tool, target: target, deadline: deadline) {
            case .approved:
                BridgeLog.info("\(tool) approved by the user", category: .tools)
                return nil
            case .declined:
                BridgeLog.info("\(tool) declined by the user", category: .tools)
                return AccessPolicy.declined(tool)
            case .timedOut:
                BridgeLog.info("\(tool) confirmation timed out", category: .tools)
                return AccessPolicy.timedOut(tool)
            }
        }
    }

    /// Show the confirmation once any earlier one has been answered.
    private func confirm(
        client: String, tool: String, target: String?, deadline: Date
    ) async -> ConfirmationPrompt.Outcome {
        let previous = confirmationTail
        let prompt = Task { @MainActor () -> ConfirmationPrompt.Outcome in
            await previous?.value
            return ConfirmationPrompt.ask(client: client, tool: tool, target: target, deadline: deadline)
        }
        confirmationTail = Task { _ = await prompt.value }
        return await prompt.value
    }

    /// Stop serving and remove the socket. Connected shims reconnect when it returns.
    func stop() {
        server?.stop()
        server = nil
        state = .stopped
    }

    private func handle(_ event: BridgeServer.Event) {
        switch event {
        case .connected(let client):
            log.note(client: client, connected: true)
            traffic.pulse()
        case .disconnected(let client):
            log.note(client: client, connected: false)
            traffic.pulse()
        case .call(let client, let tool, let ok, let detail, let summary, let duration):
            log.record(
                client: client.displayName, tool: tool, ok: ok,
                detail: detail, summary: summary, duration: duration
            )
            log.noteOutcome(of: client, ok: ok)
            switch ActivityLog.Kind.of(tool: tool) {
            case .read: traffic.send(.read, ok: ok)
            case .destructive: traffic.send(.destructive, ok: ok)
            case .write, .connection: traffic.send(.write, ok: ok)
            }
            // A denied or failed call is often a missing permission; keep the menu
            // honest without the user having to reopen it.
            if !ok { refreshPermissions() }
        case .connectionError(let message):
            // The server is still listening; only this one connection failed.
            log.record(
                client: "(unknown client)", tool: "connection refused",
                ok: false, detail: message, summary: nil, duration: 0
            )
        case .serverError(let message):
            BridgeLog.error("bridge server error: \(message)", category: .app)
            state = .failed(message)
        }
    }

    // MARK: Client health

    /// One indicator per known client, in `ClientSetup.detect` order: Claude Code,
    /// then Claude Desktop. Drawn as the dots under the menu-bar icon.
    var clientHealth: [(client: ClientSetup, health: ClientHealth)] {
        let missing = EventKitDomain.allCases.filter { !hasAccess($0) }.map(\.displayName)
        return clientSetup.map { client in
            let health = ClientHealth.evaluate(
                setup: client.status,
                connected: log.clients.contains { $0.name == client.name },
                bridgeListening: state.isListening,
                missingDomains: missing,
                totalDomains: EventKitDomain.allCases.count,
                lastCallFailed: log.clientsWithFailedLastCall.contains(client.name)
            )
            return (client, health)
        }
    }

    // MARK: Restart and diagnostics

    /// Stop and restart the socket server in place.
    ///
    /// The cheap fix for a wedged bridge, and the one that would have resolved the
    /// two-copies collision without quitting anything. Connected shims reconnect on
    /// their next call, so clients do not need restarting.
    func restartBridge() {
        BridgeLog.info("restarting the bridge on request", category: .app)
        stop()
        // A beat for the listening socket to actually close before rebinding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.start()
            self?.refreshEverything()
        }
    }

    /// Relaunch the whole app.
    ///
    /// Heavier than restarting the bridge, but it is what picks up a permission
    /// change that EventKit will not surface to already-running stores.
    func relaunchApp() {
        BridgeLog.info("relaunching the app on request", category: .app)
        let bundlePath = Bundle.main.bundlePath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n so a fresh instance starts even though one is (briefly) still running.
        process.arguments = ["-n", "-a", bundlePath]

        stop()
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Everything worth pasting into a bug report, in one block.
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("MacBridge \(MacBridge.version)")
        lines.append("bundle:     \(Bundle.main.bundlePath)")
        lines.append("binary:     \(shimPath)")
        lines.append("at login:   \(launchAtLogin)")

        switch state {
        case .listening(let path): lines.append("bridge:     listening on \(path)")
        case .stopped: lines.append("bridge:     stopped")
        case .failed(let message): lines.append("bridge:     FAILED — \(message)")
        }

        lines.append("")
        lines.append("Permissions")
        for domain in EventKitDomain.allCases {
            lines.append("  \(domain.displayName): \(statusText(domain))")
        }

        lines.append("")
        lines.append("Client setup")
        for client in clientSetup {
            let detail: String
            switch client.status {
            case .ready: detail = "configured for this app"
            case .pointsElsewhere(let command): detail = "points at \(command)"
            case .notConfigured: detail = "not set up"
            case .notInstalled: detail = "not installed"
            }
            lines.append("  \(client.name): \(detail)")
        }

        lines.append("")
        lines.append("Connected now: \(log.clients.isEmpty ? "none" : log.clients.map(\.displayName).joined(separator: ", "))")
        lines.append("Calls: \(log.totalCalls) total, \(log.failedCalls) failed")

        let recent = BridgeLog.recentLines(limit: 30)
        if !recent.isEmpty {
            lines.append("")
            lines.append("Recent log")
            // Versions before 1.8.0 logged titles in curly quotes; this report is
            // meant for a public issue, so blank any that are still in the file.
            lines.append(contentsOf: recent.map {
                "  " + $0.replacingOccurrences(
                    of: "\u{201C}[^\u{201D}]*\u{201D}", with: "\u{201C}…\u{201D}", options: .regularExpression
                )
            })
        }
        return lines.joined(separator: "\n")
    }

    /// Put ``diagnosticsReport()`` on the clipboard, for pasting into a bug report.
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport(), forType: .string)
    }

    /// Reveal the log file, creating the folder if nothing has been written yet.
    func openLog() {
        let url = BridgeLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(
                at: BridgeLog.logDirectory, withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(BridgeLog.logDirectory)
        }
    }

    /// The command a client is configured with when it is not this running copy,
    /// or nil when every configured client points here.
    ///
    /// The exact situation that made requests fail silently: an Xcode build running
    /// while the clients point at /Applications.
    var runningCopyMismatch: String? {
        for client in clientSetup {
            if case .pointsElsewhere(let command) = client.status {
                return command
            }
        }
        return nil
    }

    // MARK: Launch at login

    /// Re-read the login-item state, which the user can also change in System Settings.
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.status
        // Fixed elsewhere (System Settings, or a later attempt): drop the old error.
        if launchAtLogin == .enabled { launchAtLoginError = nil }
    }

    /// Turn "Open at login" on or off, then read back what macOS actually recorded.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
            BridgeLog.info("open at login \(enabled ? "enabled" : "disabled")", category: .app)
        } catch {
            launchAtLoginError = error.localizedDescription
            BridgeLog.error(
                "could not \(enabled ? "enable" : "disable") open at login: \(error.localizedDescription)",
                category: .app
            )
        }
        refreshLaunchAtLogin()
    }

    // MARK: Permissions

    /// Re-read permissions and client configs, which can change outside the app.
    func refreshEverything() {
        refreshPermissions()
        refreshClientSetup()
        refreshLaunchAtLogin()
    }

    /// Re-read TCC status for every domain. Never prompts.
    func refreshPermissions() {
        var next: [EventKitDomain: EKAuthorizationStatus] = [:]
        for domain in EventKitDomain.allCases {
            next[domain] = EventKitAuthorization.status(for: domain)
        }
        permissions = next
    }

    /// Whether the last refresh saw full access for `domain`.
    func hasAccess(_ domain: EventKitDomain) -> Bool {
        guard let status = permissions[domain] else { return false }
        return EventKitAuthorization.hasFullAccess(status)
    }

    /// A short word for `domain`'s last-seen status, for the panel.
    func statusText(_ domain: EventKitDomain) -> String {
        EventKitAuthorization.statusDescription(permissions[domain] ?? .notDetermined)
    }

    /// Grant prompts in flight; the Dock icon stays until the last one is answered.
    private var pendingGrantRequests = 0
    /// The activation policy to return to once no prompt is in flight.
    private var policyBeforeGrant: NSApplication.ActivationPolicy = .accessory

    /// Whether macOS policy, not the user, controls `domain`'s access.
    func isRestricted(_ domain: EventKitDomain) -> Bool {
        permissions[domain].map(EventKitAuthorization.isRestricted) ?? false
    }

    /// Prompt for a domain, or send the user to System Settings if macOS will no
    /// longer prompt — once denied, only the user can reverse it.
    func requestAccess(to domain: EventKitDomain) {
        // Read the live status rather than the cached dictionary, which may predate a
        // change made in System Settings while the panel sat open.
        let status = EventKitAuthorization.status(for: domain)
        BridgeLog.info(
            "Grant pressed for \(domain.displayName); current status: "
                + EventKitAuthorization.statusDescription(status),
            category: .permissions
        )

        if EventKitAuthorization.isRestricted(status) {
            // A profile controls this; System Settings would show a switch the user
            // can't change. The panel says so instead of offering Grant.
            BridgeLog.info("\(domain.displayName) is restricted by policy", category: .permissions)
            return
        }
        guard EventKitAuthorization.canPrompt(status) else {
            // Once macOS has a decision on record it will never prompt again, so the
            // only route left is System Settings.
            BridgeLog.info(
                "\(domain.displayName) already decided — opening System Settings",
                category: .permissions
            )
            openPrivacySettings(for: domain)
            return
        }

        // A menu-bar-only app runs as an "accessory" and is never the frontmost app,
        // so macOS has nothing to attach the TCC prompt to and the request returns
        // silently — which is exactly the "clicking Grant does nothing" symptom.
        // Becoming a regular app for the duration gives the prompt somewhere to go.
        //
        // Counted, because Grant can be pressed for both domains before the first
        // prompt is answered: saving "the previous policy" per request made the
        // second one save `.regular` and restore it last, leaving a Dock icon.
        if pendingGrantRequests == 0 {
            policyBeforeGrant = NSApp.activationPolicy()
        }
        pendingGrantRequests += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            // A store created before the grant can keep serving the old answer, so the
            // request gets a fresh one.
            let store = EKEventStore()
            do {
                try await EventKitAuthorization.ensureAccess(to: domain, store: store)
                BridgeLog.info("\(domain.displayName) granted", category: .permissions)
            } catch {
                BridgeLog.warning(
                    "\(domain.displayName) not granted: \(error.localizedDescription)",
                    category: .permissions
                )
                // macOS offers the upgrade from write-only once. Declined, it stays
                // write-only and later requests return at once with no prompt, so
                // Grant would look dead again; System Settings is the way forward.
                if EventKitAuthorization.status(for: domain).rawValue == 4 {
                    openPrivacySettings(for: domain)
                }
            }
            pendingGrantRequests -= 1
            if pendingGrantRequests == 0 {
                NSApp.setActivationPolicy(policyBeforeGrant)
            }
            refreshPermissions()
        }
    }

    /// Open the Privacy pane for a domain.
    ///
    /// The URL scheme changed when System Preferences became System Settings, and a
    /// scheme the current macOS does not recognise simply does nothing — no error, no
    /// window — so both forms are tried and the outcome is logged rather than assumed.
    func openPrivacySettings(for domain: EventKitDomain) {
        let anchor: String
        switch domain {
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        }

        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                BridgeLog.info("opened System Settings via \(candidate)", category: .permissions)
                return
            }
        }

        BridgeLog.warning(
            "could not open System Settings for \(domain.displayName); "
                + "open Privacy & Security → \(domain.displayName) manually",
            category: .permissions
        )
    }

    // MARK: Client setup

    /// The exact path a client must be pointed at: the binary inside this bundle,
    /// so an update to the app updates the shim with it.
    var shimPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/macbridge")
            .path
    }

    var toolCount: Int { ToolRegistry.definitions().count }

    /// What happened when the user clicked Connect for a client.
    struct SetupResult: Equatable {
        let clientID: String
        let message: String
        let isError: Bool
    }

    /// Point a client at this copy of the app, in one click.
    ///
    /// Claude Desktop's config is a plain JSON file, so it is merged directly by
    /// `ClientConfigWriter`. Claude Code's `~/.claude.json` is large and rewritten by
    /// Claude Code itself while it runs, so that one goes through `claude mcp add`
    /// rather than an edit that could race it.
    func connect(_ client: ClientSetup) {
        switch client.id {
        case "claude-desktop":
            do {
                try ClientConfigWriter.install(shimPath: shimPath,
                                               configAt: URL(fileURLWithPath: client.configPath))
                BridgeLog.info("added MacBridge to Claude Desktop's config", category: .app)
                setupResult = SetupResult(
                    clientID: client.id,
                    message: "Added. Quit and reopen Claude Desktop to finish.",
                    isError: false
                )
            } catch {
                BridgeLog.error("couldn't update Claude Desktop's config: \(error)", category: .app)
                setupResult = SetupResult(clientID: client.id,
                                          message: error.localizedDescription, isError: true)
            }
            refreshClientSetup()

        case "claude-code":
            guard let cli = claudeCLIPath else {
                setupResult = SetupResult(
                    clientID: client.id,
                    message: "The claude command wasn't found. Install Claude Code, then try again.",
                    isError: true
                )
                return
            }
            connectingClientID = client.id
            let shim = shimPath
            let config = URL(fileURLWithPath: client.configPath)
            Task {
                let result = await Self.addToClaudeCode(cli: cli, shimPath: shim, config: config)
                connectingClientID = nil
                setupResult = SetupResult(clientID: client.id, message: result.message,
                                          isError: !result.ok)
                refreshClientSetup()
            }

        default:
            break
        }
    }

    /// Take MacBridge out of a client's configuration: the reverse of ``connect(_:)``.
    /// Entries the user set up with flags of their own are left, as Connect leaves
    /// them; the config is backed up the same way.
    func disconnect(_ client: ClientSetup) {
        switch client.id {
        case "claude-desktop":
            do {
                let removed = try ClientConfigWriter.uninstall(configAt: URL(fileURLWithPath: client.configPath))
                BridgeLog.info("removed MacBridge from Claude Desktop's config (\(removed.count) entries)", category: .app)
                setupResult = SetupResult(
                    clientID: client.id,
                    message: removed.isEmpty
                        ? "MacBridge wasn't in Claude Desktop's config."
                        : "Removed. Quit and reopen Claude Desktop to finish.",
                    isError: false
                )
            } catch {
                BridgeLog.error("couldn't update Claude Desktop's config: \(error)", category: .app)
                setupResult = SetupResult(clientID: client.id, message: error.localizedDescription, isError: true)
            }
            refreshClientSetup()

        case "claude-code":
            guard let cli = claudeCLIPath else {
                setupResult = SetupResult(
                    clientID: client.id,
                    message: "The claude command wasn't found. Run `claude mcp remove --scope user macbridge` yourself.",
                    isError: true
                )
                return
            }
            connectingClientID = client.id
            let config = URL(fileURLWithPath: client.configPath)
            Task {
                let result = await Self.removeFromClaudeCode(cli: cli, config: config)
                connectingClientID = nil
                setupResult = SetupResult(clientID: client.id, message: result.message, isError: !result.ok)
                refreshClientSetup()
            }

        default:
            break
        }
    }

    /// `claude mcp remove --scope user` for our entry and any plain stale copy,
    /// off the main thread for the same reason as ``addToClaudeCode(cli:shimPath:config:)``.
    private nonisolated static func removeFromClaudeCode(cli: String, config: URL) async -> (ok: Bool, message: String) {
        await Task.detached {
            let names = ClientConfigWriter.reAddPlan(forConfigAt: config).remove
            guard !names.isEmpty else { return (true, "MacBridge wasn't set up in Claude Code.") }
            let failed = names.filter { run(cli, ["mcp", "remove", "--scope", "user", $0]).status != 0 }
            if failed.isEmpty {
                BridgeLog.info("removed MacBridge from Claude Code (user scope)", category: .app)
                return (true, "Removed. New Claude Code sessions won't see MacBridge.")
            }
            BridgeLog.error("claude mcp remove failed for \(failed.count) entries", category: .app)
            return (false, "claude mcp remove failed for: \(failed.joined(separator: ", ")).")
        }.value
    }

    /// Run `claude mcp add --scope user` off the main thread, first removing our
    /// entry and any plain stale copy of it, whatever it's named (`add` refuses a
    /// name that already exists, and a stale one would launch alongside). Flags the
    /// user added after `mcp`, and entries they set up with flags of their own, are
    /// kept, as for Claude Desktop — see ``ClientConfigWriter/reAddPlan(forConfigAt:)``.
    ///
    /// `~/.claude.json` is read here rather than on the main thread: it is often
    /// several megabytes.
    private nonisolated static func addToClaudeCode(
        cli: String, shimPath: String, config: URL
    ) async -> (ok: Bool, message: String) {
        await Task.detached {
            let plan = ClientConfigWriter.reAddPlan(forConfigAt: config)
            let removed = plan.remove.filter { run(cli, ["mcp", "remove", "--scope", "user", $0]).status == 0 }
            let added = run(cli, ["mcp", "add", "--scope", "user", ClientConfigWriter.serverKey,
                                  "--", shimPath, "mcp"] + plan.flags)
            if added.status == 0 {
                BridgeLog.info("added MacBridge to Claude Code (user scope)", category: .app)
                return (true, "Added. New Claude Code sessions will see MacBridge.")
            }
            BridgeLog.error("claude mcp add failed (\(added.status)): \(added.output)", category: .app)
            let detail = added.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var message = detail.isEmpty ? "claude mcp add failed." : "claude mcp add failed: \(detail)"
            if !removed.isEmpty {
                message += " The old MacBridge entry was removed; click Connect to try again."
            }
            return (false, message)
        }.value
    }

    /// Run a command to completion and return its exit status and combined output.
    ///
    /// A GUI app inherits almost no PATH, and an npm-installed `claude` is a script
    /// that needs `node`, so the usual install locations are added. A command still
    /// running after `timeout` seconds is stopped, so a hung `claude` can't leave the
    /// Connect button disabled until the app restarts.
    private nonisolated static func run(
        _ path: String, _ arguments: [String], timeout: TimeInterval = 30
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // A command that ignores SIGTERM would keep the pipe open and the button
            // disabled, so it gets a moment and then SIGKILL.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read to the end before waiting: a full pipe would otherwise block the
        // child, and the child would never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut.isSet {
            return (-1, "it didn't finish within \(Int(timeout)) seconds")
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Put the JSON entry on the clipboard, for the Manual setup fallback when Connect
    /// can't write the config itself.
    func copyClientConfiguration() {
        let json = """
            {
              "mcpServers": {
                "macbridge": {
                  "command": "\(shimPath)",
                  "args": ["mcp"]
                }
              }
            }
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    /// The `claude mcp add` command that points Claude Code at this copy's shim.
    ///
    /// `--scope user` matters: without it Claude Code saves the server for the one
    /// folder the command ran in, and `ClientSetup`, which reads the user-wide list,
    /// never sees it.
    var claudeCodeCommand: String {
        "claude mcp add --scope user macbridge -- \(shimPath) mcp"
    }

    /// Put ``claudeCodeCommand`` on the clipboard, for pasting into a terminal.
    func copyClaudeCodeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeCodeCommand, forType: .string)
    }

    /// Open the folder holding a client's config file, for the JSON route.
    func revealConfig(at path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// Set by the `run` watchdog when it stops a command, so a timeout can be told apart
/// from a command that crashed on its own.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
