//
//  MenuContent.swift
//  MacBridge (app) · MacBridge
//
//  The menu-bar panel: status, permissions, clients, activity, diagnostics.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import MacBridgeKit
import SwiftUI

/// The menu-bar panel: whether the bridge is up, what is granted, who is
/// connected, and what they just did.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    /// Observed separately: `AppModel.log` is itself an ObservableObject, and a
    /// nested one does not republish through its parent, so watching only `model`
    /// would leave the activity list frozen.
    @ObservedObject var log: ActivityLog
    @ObservedObject var traffic: BridgeTraffic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let other = model.runningCopyMismatch {
                copyMismatchWarning(other)
            }
            Divider()
            permissions
            Divider()
            safety
            Divider()
            setup
            Divider()
            clients
            Divider()
            activity
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
        // Permissions and login items can both change in System Settings while the
        // panel is closed, so each opening re-reads them. Both reads are cheap.
        .onAppear {
            model.refreshPermissions()
            model.refreshLaunchAtLogin()
        }
    }

    /// A section's small caps title, read by VoiceOver as a heading so the panel
    /// can be navigated section by section.
    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(title)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacBridge \(MacBridge.version)")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(model.toolCount) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                clientDots
            }
        }
    }

    /// The menu-bar dots for installed clients, with names, and the reason on hover.
    private var clientDots: some View {
        HStack(spacing: 8) {
            // Absent clients are left out, as in the right-click menu: a client that
            // isn't installed has nothing to report.
            ForEach(model.clientHealth.filter { $0.health.level != .absent }, id: \.client.id) { entry in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(nsColor: StatusDotsView.color(for: entry.health.level)))
                        .frame(width: 6, height: 6)
                    Text(entry.client.name.replacingOccurrences(of: "Claude ", with: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("\(entry.client.name): \(entry.health.reason)")
                // The dot's colour is the status; VoiceOver gets the words instead.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.client.name): \(entry.health.reason)")
            }
        }
    }

    /// The failure that is otherwise invisible: this app running while the clients
    /// are configured for a different copy, so calls go to whichever grabbed the
    /// socket — possibly one with no permissions.
    @ViewBuilder
    private func copyMismatchWarning(_ otherPath: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Another copy is configured")
                    .font(.caption.weight(.semibold))
            }
            Text("Your client points at a different MacBridge, so this one will not serve it:")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(otherPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch model.state {
        case .listening: return .green
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.state {
        case .listening:
            let calls = log.totalCalls
            guard calls > 0 else { return "Listening — no calls yet" }
            return "Listening — \(calls) call\(calls == 1 ? "" : "s")"
                + (log.failedCalls > 0 ? ", \(log.failedCalls) failed" : "")
        case .stopped:
            return "Not listening"
        case .failed(let message):
            return message
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Permissions")

            ForEach(EventKitDomain.allCases, id: \.self) { domain in
                HStack(spacing: 6) {
                    // An HStack, not a Group: a Group's modifiers apply to each child
                    // separately, so .combine on it would merge nothing.
                    HStack(spacing: 6) {
                        Image(systemName: model.hasAccess(domain) ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.hasAccess(domain) ? .green : .orange)
                            .accessibilityHidden(true)
                        Text(domain.displayName)
                        Text(model.isRestricted(domain) ? "managed by your organization" : model.statusText(domain))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    // A restricted domain can't be granted here or in System Settings,
                    // so a Grant button would lead nowhere.
                    if !model.hasAccess(domain) && !model.isRestricted(domain) {
                        Button("Grant…") { model.requestAccess(to: domain) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Safety

    /// What connected clients may do. Read-only covers every write; asking before
    /// deleting covers the three tools that can't be undone.
    private var safety: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Safety")

            Toggle("Read-only", isOn: $model.policy.readOnly)
                .toggleStyle(.checkbox)
            Text(model.policy.readOnly
                 ? "Clients can read your calendars and reminders but not change them."
                 : "Clients can add, change and complete items.")
                .font(.caption2)
                .foregroundStyle(model.policy.readOnly ? .orange : .secondary)
                .padding(.leading, 20)

            Toggle("Ask before deleting", isOn: $model.policy.confirmDestructive)
                .toggleStyle(.checkbox)
                .disabled(model.policy.readOnly)
            Text("Deleting an event, reminder or list waits for you to allow it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    // MARK: Setup

    /// What the user has to do for any of this to be useful.
    ///
    /// MacBridge is only half of the setup: a client has to be told to run
    /// `macbridge mcp`. Nothing errors if that never happens — the app just sits
    /// here with no clients — so this section says so in as many words.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Client Setup")
                Spacer()
                Button("Re-check") { model.refreshClientSetup() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            if !model.hasConfiguredClient {
                Text("No AI client is pointed at MacBridge yet, so nothing can use it. Add it to one below.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.clientSetup) { client in
                clientSetupRow(client)
            }
        }
    }

    @ViewBuilder
    private func clientSetupRow(_ client: ClientSetup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: client.status))
                    .foregroundStyle(tint(for: client.status))
                    .accessibilityHidden(true)
                Text(client.name)
                Spacer()
                Text(label(for: client.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            switch client.status {
            case .ready:
                HStack(spacing: 6) {
                    // Keep the "restart Claude Desktop" reminder visible after Connect,
                    // since the row flips to ready the moment the config is written.
                    if let result = model.setupResult, result.clientID == client.id, !result.isError {
                        Text(result.message)
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.connectingClientID == client.id {
                        ProgressView().controlSize(.mini)
                    }
                    Button("Disconnect") { model.disconnect(client) }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .disabled(model.connectingClientID == client.id)
                        .help("Remove MacBridge from \(client.name)'s settings. Connect adds it back.")
                }

            case .notInstalled:
                Text("Not installed on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            case .pointsElsewhere(let command):
                // Almost always a config left over from a DerivedData build, which
                // fails only when the user next tries to use it.
                Text("Configured, but pointing at another copy:")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                setupActions(for: client)

            case .notConfigured:
                setupActions(for: client)
            }
        }
    }

    /// One click to connect a client, with the copy-and-paste routes kept as a
    /// fallback for when the click can't do it (no `claude` CLI, unreadable config).
    @ViewBuilder
    private func setupActions(for client: ClientSetup) -> some View {
        let isRepair = client.status != .notConfigured
        let isConnecting = model.connectingClientID == client.id
        HStack(spacing: 6) {
            Button(isRepair ? "Fix Connection" : "Connect \(client.name)") { model.connect(client) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            if isConnecting {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Menu("Manual setup") {
                if client.id == "claude-code" {
                    Button("Copy Terminal Command") { model.copyClaudeCodeCommand() }
                }
                Button("Copy JSON") { model.copyClientConfiguration() }
                Button("Reveal Config File") { model.revealConfig(at: client.configPath) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption2)
        }

        if let result = model.setupResult, result.clientID == client.id {
            Text(result.message)
                .font(.caption2)
                .foregroundStyle(result.isError ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func icon(for status: ClientSetup.Status) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .pointsElsewhere: return "exclamationmark.triangle.fill"
        case .notConfigured: return "circle.dashed"
        case .notInstalled: return "minus.circle"
        }
    }

    private func tint(for status: ClientSetup.Status) -> Color {
        switch status {
        case .ready: return .green
        case .pointsElsewhere: return .orange
        case .notConfigured: return .orange
        case .notInstalled: return .secondary
        }
    }

    private func label(for status: ClientSetup.Status) -> String {
        switch status {
        case .ready: return "connected to this app"
        case .pointsElsewhere: return "wrong path"
        case .notConfigured: return "not set up"
        case .notInstalled: return "not installed"
        }
    }

    // MARK: Clients

    private var clients: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Connected Clients")
                Spacer()
                Text("\(log.clients.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if log.clients.isEmpty {
                Text("None. Point an AI client at this app to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.clients) { client in
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(client.displayName)
                        Spacer()
                        // This row is where per-client allow/deny will live.
                        Text("pid \(client.pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Activity

    /// A glanceable summary: live traffic and the last few calls.
    ///
    /// The panel deliberately does not scroll: it is a status view, not a log. The
    /// durable record is `BridgeLog`'s file, reachable from Open Log.
    private var activity: some View {
        let rows = log.recent
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent Activity")

            BridgeTrafficView(
                traffic: traffic,
                alert: !model.state.isListening,
                client: log.clients.count == 1 ? log.clients[0].displayName
                    : log.clients.isEmpty ? nil : "\(log.clients.count) clients"
            )

            if rows.isEmpty {
                Text("No tool calls yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { entry in
                    HStack(spacing: 6) {
                        Text(entry.timeText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.tool)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.ok ? Color.primary : Color.red)
                            .lineLimit(1)
                        if entry.repeatCount > 1 {
                            Text("×\(entry.repeatCount)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !entry.ok, let detail = entry.detail {
                            // Why it failed, which the row used to keep to itself;
                            // the whole message is a hover away.
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else if let summary = entry.summary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(entry.ok ? "" : entry.detail ?? "")
                    // Red is the only sign of a failure on screen; say it.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(activityLabel(entry))
                }

                if log.totalCalls > rows.count {
                    Text("\(log.totalCalls) calls total"
                        + (log.failedCalls > 0 ? ", \(log.failedCalls) failed" : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// One activity row in words: the time, the tool, whether it failed and why.
    private func activityLabel(_ entry: ActivityLog.Entry) -> String {
        var parts = [entry.timeText, entry.tool]
        if entry.repeatCount > 1 { parts.append("\(entry.repeatCount) times") }
        if entry.ok {
            if let summary = entry.summary { parts.append(summary) }
        } else {
            parts.append("failed")
            if let detail = entry.detail { parts.append(detail) }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This app's binary, which clients invoke:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(model.shimPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            sectionTitle("Diagnostics")
            HStack(spacing: 6) {
                Button("Open Log") { model.openLog() }
                    .controlSize(.small)
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                    .controlSize(.small)
                Button("Refresh") { model.refreshEverything() }
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                // Restarting the bridge is the cheap fix for a wedged connection;
                // connected clients reconnect on their next call, so it is safe.
                Button("Restart Bridge") { model.restartBridge() }
                    .controlSize(.small)
                Button("Relaunch App") { model.relaunchApp() }
                    .controlSize(.small)
                Spacer()
            }
            Text("Restart Bridge rebinds the socket. Relaunch also picks up permission changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            launchAtLogin

            Divider()

            HStack {
                Button("About MacBridge") { AboutWindow.show() }
                    .controlSize(.small)
                Spacer()
                Button("Quit MacBridge") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Launch at login

    /// The "Open at login" checkbox. Its value is what macOS has on record, not a
    /// stored preference, so switching it off in System Settings unticks it here.
    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open MacBridge at login", isOn: Binding(
                get: { model.launchAtLogin != .disabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!LaunchAtLogin.isAvailable)

            if !LaunchAtLogin.isAvailable {
                Text("Available once MacBridge is in your Applications folder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if model.launchAtLogin == .requiresApproval {
                HStack(spacing: 6) {
                    Text("Switched off in System Settings.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                        .controlSize(.small)
                }
            } else if let error = model.launchAtLoginError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Keeps the bridge ready for your AI clients after a restart.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
