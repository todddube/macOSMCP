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
    @Published var log = ActivityLog()
    /// The animated traffic in the menu-bar icon and the panel. Not `@Published`:
    /// it ticks at 30fps while busy, and only the views drawing it should redraw.
    let traffic = BridgeTraffic()

    private let registry = ToolRegistry()
    private var server: BridgeServer?

    /// One store, used only for permission checks and requests. The services in
    /// MacBridgeKit hold their own.
    private let permissionStore = EKEventStore()

    /// Reads permissions and client setup; the server waits for ``start()``.
    init() {
        refreshPermissions()
        refreshClientSetup()
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
                // Allows every call for now; this is where the consent store and a
                // confirmation sheet for destructive tools will attach.
                authorize: nil,
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
            lines.append(contentsOf: recent.map { "  " + $0 })
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

    // MARK: Permissions

    /// Re-read permissions and client configs, which can change outside the app.
    func refreshEverything() {
        refreshPermissions()
        refreshClientSetup()
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

        guard status == .notDetermined else {
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
        let previousPolicy = NSApp.activationPolicy()
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
            }
            NSApp.setActivationPolicy(previousPolicy)
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

    /// Offered for pasting; writing the client config files directly is planned.
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
    var claudeCodeCommand: String {
        "claude mcp add macbridge -- \(shimPath) mcp"
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
