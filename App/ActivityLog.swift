//
//  ActivityLog.swift
//  MacBridge (app) · MacBridge
//
//  Connected clients and recent tool calls, for the menu-bar panel.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MacBridgeKit

/// The record of what connected clients have been doing.
///
/// The point is that tool calls stop being invisible. A bounded in-memory log is
/// enough for that — it is a live view, not an audit trail, and deliberately never
/// written to disk. The durable record is `BridgeLog`'s file.
@MainActor
final class ActivityLog: ObservableObject {

    /// What kind of thing happened, which decides how a row is presented.
    enum Kind: Sendable {
        case read
        case write
        case destructive
        case connection

        /// How a tool call is classed; connections are never tool calls.
        static func of(tool: String) -> Kind {
            if ToolRegistry.destructiveToolNames.contains(tool) { return .destructive }
            if ToolRegistry.isReadOnly(tool) { return .read }
            return .write
        }
    }

    /// One row: a tool call, or a client connecting or leaving.
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let at: Date
        let client: String
        let tool: String
        let ok: Bool
        let detail: String?
        /// A few words on what the call did — "14 lists", "created “Buy milk”".
        let summary: String?
        let duration: TimeInterval
        let kind: Kind
        /// Consecutive identical calls are counted rather than repeated.
        var repeatCount: Int = 1

        var timeText: String { Entry.timeFormatter.string(from: at) }

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()
    }

    /// Newest first, so the panel reads top-down without reversing on every render.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var clients: [ClientIdentity] = []
    @Published private(set) var totalCalls = 0
    @Published private(set) var failedCalls = 0
    /// Client names whose most recent call failed, for the menu-bar indicators.
    /// Keyed by `ClientIdentity.name` rather than the versioned display name, so it
    /// lines up with `ClientSetup.name`.
    @Published private(set) var clientsWithFailedLastCall: Set<String> = []

    private let limit = 500

    /// Tool calls only. Connections are recorded too but must never crowd out the
    /// calls, which are the thing worth seeing.
    var toolCalls: [Entry] { entries.filter { $0.kind != .connection } }

    /// The handful shown inline in the menu-bar panel.
    var recent: [Entry] { Array(toolCalls.prefix(4)) }

    // MARK: Recording

    /// Add a completed tool call, folding it into the previous row when it repeats
    /// that row within two minutes.
    func record(
        client: String,
        tool: String,
        ok: Bool,
        detail: String?,
        summary: String?,
        duration: TimeInterval
    ) {
        let kind = Kind.of(tool: tool)
        let entry = Entry(
            at: Date(), client: client, tool: tool, ok: ok,
            detail: detail, summary: summary, duration: duration, kind: kind
        )

        totalCalls += 1
        if !ok { failedCalls += 1 }

        // Collapse a repeat of the immediately preceding call rather than filling the
        // list with the same row. A model polling the same search would otherwise push
        // everything else out.
        if var previous = entries.first,
           previous.tool == entry.tool,
           previous.client == entry.client,
           previous.ok == entry.ok,
           previous.summary == entry.summary,
           entry.at.timeIntervalSince(previous.at) < 120 {
            previous.repeatCount += 1
            entries[0] = previous
            return
        }

        insert(entry)
    }

    /// Remember whether a client's latest call worked. A success clears the
    /// warning, so one bad call does not leave a client yellow for the session.
    func noteOutcome(of client: ClientIdentity, ok: Bool) {
        if ok {
            clientsWithFailedLastCall.remove(client.name)
        } else {
            clientsWithFailedLastCall.insert(client.name)
        }
    }

    /// Track a client connecting or disconnecting, and log it as a connection row.
    func note(client: ClientIdentity, connected: Bool) {
        if connected {
            if !clients.contains(where: { $0.id == client.id }) { clients.append(client) }
        } else {
            clients.removeAll { $0.id == client.id }
            // Another session of the same client may still be connected; only clear
            // the warning once the last one has gone.
            if !clients.contains(where: { $0.name == client.name }) {
                clientsWithFailedLastCall.remove(client.name)
            }
        }

        insert(
            Entry(
                at: Date(),
                client: client.displayName,
                tool: connected ? "connected" : "disconnected",
                ok: true,
                detail: connected ? "pid \(client.pid)" : nil,
                summary: nil,
                duration: 0,
                kind: .connection
            )
        )
    }

    /// The one place entries are added, so the cap cannot be bypassed.
    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
