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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacBridge \(MacBridge.version)")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text("PERMISSIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(EventKitDomain.allCases, id: \.self) { domain in
                HStack(spacing: 6) {
                    Image(systemName: model.hasAccess(domain) ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.hasAccess(domain) ? .green : .orange)
                    Text(domain.displayName)
                    Text(model.statusText(domain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.hasAccess(domain) {
                        Button("Grant…") { model.requestAccess(to: domain) }
                            .controlSize(.small)
                    }
                }
            }
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
                Text("CLIENT SETUP")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                Text(client.name)
                Spacer()
                Text(label(for: client.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch client.status {
            case .ready:
                EmptyView()

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

    /// The two ways to add MacBridge to a client: the CLI command, or the JSON file.
    @ViewBuilder
    private func setupActions(for client: ClientSetup) -> some View {
        if client.id == "claude-code" {
            if model.claudeCLIPath != nil {
                Text("Run this in a terminal:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.claudeCodeCommand)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Button("Copy command") { model.copyClaudeCodeCommand() }
                        .controlSize(.small)
                    Button("Copy JSON instead") { model.copyClientConfiguration() }
                        .controlSize(.small)
                }
            } else {
                // The `claude mcp add` route needs the CLI; without it, say so rather
                // than showing a command that will not run.
                Text("The claude CLI was not found, so add it to the config file instead:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Copy JSON") { model.copyClientConfiguration() }
                        .controlSize(.small)
                    Button("Reveal config") { model.revealConfig(at: client.configPath) }
                        .controlSize(.small)
                }
            }
        } else {
            Text("Add this to its config, then restart it:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Copy JSON") { model.copyClientConfiguration() }
                    .controlSize(.small)
                Button("Reveal config") { model.revealConfig(at: client.configPath) }
                    .controlSize(.small)
            }
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
                Text("CONNECTED CLIENTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                        Text(client.displayName)
                        Spacer()
                        // This row is where per-client allow/deny will live.
                        Text("pid \(client.pid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            Text("RECENT ACTIVITY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

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
                        if let summary = entry.summary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
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

            Text("DIAGNOSTICS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
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

            HStack {
                Button("About MacBridge") { AboutWindow.show() }
                    .controlSize(.small)
                Spacer()
                Button("Quit MacBridge") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}
