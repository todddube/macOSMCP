//
//  ToolRegistry.swift
//  MacBridgeKit · MacBridge
//
//  The one place that knows which tools exist and what they dispatch to.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// The single place that knows which tools exist and what they dispatch to.
///
/// Both faces of MacBridge go through here: the app owns it and the CLI shim
/// forwards across the socket, while `mcp --direct` serves it over stdio in the
/// CLI process. Consent decisions stay out of the registry so the app can wrap
/// `call` without the registry ever knowing about clients.
public actor ToolRegistry {

    private let calendar: CalendarService
    private let reminders: RemindersService

    /// Builds the name-to-handler table over the given services.
    public init(calendar: CalendarService = CalendarService(), reminders: RemindersService = RemindersService()) {
        self.calendar = calendar
        self.reminders = reminders
        self.handlers = [
            "calendar_list_calendars":       { _ in try await calendar.listCalendars() },
            "calendar_search_events":        { try await calendar.searchEvents($0) },
            "calendar_create_event":         { try await calendar.createEvent($0) },
            "calendar_update_event":         { try await calendar.updateEvent($0) },
            "calendar_reschedule_event":     { try await calendar.rescheduleEvent($0) },
            "calendar_cancel_event":         { try await calendar.cancelEvent($0) },
            "calendar_open_event":           { try await calendar.openEvent($0) },
            "calendar_find_available_times": { try await calendar.findAvailableTimes($0) },

            "reminders_list_lists":          { try await reminders.listLists($0) },
            "reminders_search_reminders":    { try await reminders.searchReminders($0) },
            "reminders_create_reminder":     { try await reminders.createReminder($0) },
            "reminders_update_reminder":     { try await reminders.updateReminder($0) },
            "reminders_complete_reminder":   { try await reminders.completeReminder($0) },
            "reminders_delete_reminder":     { try await reminders.deleteReminder($0) },
            "reminders_open_reminder":       { try await reminders.openReminder($0) },
            "reminders_create_list":         { try await reminders.createList($0) },
            "reminders_update_list":         { try await reminders.updateList($0) },
            "reminders_delete_list":         { try await reminders.deleteList($0) },
        ]
    }

    // MARK: Definitions

    /// Every tool, in a stable order so `tools/list` output is diffable.
    public nonisolated static func definitions() -> [Tool] {
        CalendarTools.definitions() + RemindersTools.definitions()
    }

    /// Every tool name, in ``definitions()`` order.
    public nonisolated static var toolNames: [String] {
        definitions().map(\.name)
    }

    /// Tools that destroy data: the set the planned confirmation step will gate.
    /// Nothing enforces confirmation yet; clients are asked to confirm instead.
    ///
    /// Read from the definitions' own `destructiveHint` rather than a second
    /// hand-maintained list, so a new destructive tool lands in the set
    /// automatically.
    public nonisolated static var destructiveToolNames: Set<String> {
        Set(definitions().filter { $0.annotations.destructiveHint == true }.map(\.name))
    }

    /// True when a tool only reads. Used to mark writes in the activity list, where
    /// a delete previously looked identical to a search.
    public nonisolated static func isReadOnly(_ toolName: String) -> Bool {
        definitions().first { $0.name == toolName }?.annotations.readOnlyHint == true
    }

    /// The domain a tool belongs to, from its name prefix; nil for an unknown name.
    public nonisolated static func domain(of toolName: String) -> EventKitDomain? {
        EventKitDomain.allCases.first { toolName.hasPrefix($0.toolPrefix) }
    }

    // MARK: Dispatch

    private typealias Handler = @Sendable (Arguments) async throws -> Value

    /// Name → handler, built once at init.
    ///
    /// A dictionary rather than a switch so `routedToolNames` can be compared
    /// against the advertised inventory without calling anything. A switch would
    /// have to be mirrored by a second hand-written list, and the two would drift
    /// the first time a tool was added.
    private let handlers: [String: Handler]

    /// Every tool this registry can actually execute.
    ///
    /// Checked against `definitions()` by the self-test, which is how a tool that
    /// is advertised but never wired up gets caught before a model finds it.
    public var routedToolNames: Set<String> { Set(handlers.keys) }

    /// Route a call to its service.
    ///
    /// Throws `MacBridgeError`; the transport layer turns that into an MCP error
    /// result so the model sees the message rather than a dropped connection.
    public func call(_ name: String, arguments: [String: Value]?) async throws -> Value {
        guard let handler = handlers[name] else {
            throw MacBridgeError.unknownTool(name)
        }
        return try await handler(Arguments(arguments))
    }
}
