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

    /// Tools that destroy data: the set ``AccessPolicy`` holds for confirmation.
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

    /// True when a tool can change the user's data: everything that isn't read-only,
    /// except the `*_open_*` tools, which only reveal an item in Calendar or
    /// Reminders. What Read-only mode refuses.
    public nonisolated static func changesData(_ toolName: String) -> Bool {
        guard let tool = definitions().first(where: { $0.name == toolName }) else { return false }
        return tool.annotations.readOnlyHint != true && !toolName.contains("_open_")
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
        try Self.checkArgumentNames(tool: name, arguments: arguments)
        return try await handler(Arguments(arguments))
    }

    /// True when a call may remove data, so Ask before deleting holds it for the
    /// user: the destructive tools, and an event update that changes the repeat,
    /// which drops the occurrences that no longer fit.
    ///
    /// Decided from the name and argument names alone. Whether the event really
    /// repeats is checked afterwards by ``confirmation(_:arguments:)``.
    public nonisolated static func mayRemoveData(_ toolName: String, arguments: [String: Value]?) -> Bool {
        if destructiveToolNames.contains(toolName) { return true }
        guard toolName == "calendar_update_event", let keys = arguments?.keys else { return false }
        return !Recurrence.argumentNames.isDisjoint(with: keys)
    }

    /// Whether a call ``mayRemoveData(_:arguments:)`` flagged really needs asking
    /// about, and what it would remove, in words for the prompt.
    ///
    /// Only a repeat change can turn out not to: making a one-off event repeat
    /// loses nothing, and a change the call would refuse isn't worth asking about.
    /// A destructive tool whose target can't be looked up still asks.
    public func confirmation(_ name: String, arguments: [String: Value]?) async -> (needed: Bool, target: String?) {
        if name == "calendar_update_event" {
            return await calendar.repeatChangeTarget(Arguments(arguments))
        }
        return (true, await confirmationTarget(name, arguments: arguments))
    }

    /// What a destructive call would remove, in words for a confirmation prompt —
    /// "the event “Standup” on 19 Oct 2026 at 10:00 (this occurrence only)" — or nil
    /// when it can't be looked up, in which case the prompt says less but still asks.
    /// Only reads.
    public func confirmationTarget(_ name: String, arguments: [String: Value]?) async -> String? {
        let args = Arguments(arguments)
        switch name {
        case "calendar_cancel_event": return await calendar.confirmationTarget(args)
        case "reminders_delete_reminder", "reminders_delete_list": return await reminders.confirmationTarget(name, args)
        default: return nil
        }
    }

    // MARK: Argument names

    /// Spellings the services read but the schemas do not advertise, kept so that
    /// calls which worked before unknown names were refused still work.
    private static let hiddenAliases: [String: Set<String>] = [
        "calendar_search_events": ["calendar"],
        "calendar_find_available_times": ["calendar"],
        "calendar_update_event": ["id"],
        "calendar_reschedule_event": ["id"],
        "calendar_cancel_event": ["id"],
        // Search results pair id with occurrence_date; revealing any occurrence
        // shows the event, so the date is accepted and ignored.
        "calendar_open_event": ["id", "occurrence_date"],
        "reminders_search_reminders": ["lists"],
        "reminders_update_reminder": ["id"],
        "reminders_complete_reminder": ["id"],
        "reminders_delete_reminder": ["id"],
        "reminders_open_reminder": ["id"],
        "reminders_update_list": ["list_id"],
        "reminders_delete_list": ["list_id"],
    ]

    /// The tools with hidden aliases, so a test can catch one left behind by a rename.
    static var aliasedToolNames: Set<String> { Set(hiddenAliases.keys) }

    /// Each tool's advertised argument names, from its schema.
    private static let advertisedArguments: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: definitions().map { tool in
            (tool.name, Set(tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? []))
        }
    )

    /// Refuse argument names a tool does not take.
    ///
    /// A misspelt name used to be ignored silently, so `reminders_create_reminder`
    /// with `due_date` made an undated reminder and reported success, and
    /// `calendar_search_events` with `calendar_id` searched every calendar.
    /// Refusing costs the model one retry; the silent version cost the user data.
    static func checkArgumentNames(tool: String, arguments: [String: Value]?) throws {
        guard let arguments, !arguments.isEmpty else { return }
        let advertised = advertisedArguments[tool] ?? []
        let accepted = advertised.union(hiddenAliases[tool] ?? [])
        let unknown = arguments.keys.filter { !accepted.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }

        var suggestions: [String: String] = [:]
        for name in unknown {
            if let guess = closestName(to: name, among: advertised) { suggestions[name] = guess }
        }
        throw MacBridgeError.unknownArguments(
            tool: tool, names: unknown, suggestions: suggestions, accepted: advertised.sorted()
        )
    }

    /// The advertised name a model most plausibly meant: one that contains, or is
    /// contained in, the unknown name once an `_id`/`_date` style suffix is dropped
    /// (`due_date` → `due`), else the nearest by edit distance if it is close.
    static func closestName(to name: String, among candidates: Set<String>) -> String? {
        let lowered = name.lowercased()
        let stem = lowered.replacingOccurrences(
            of: #"_(id|ids|date|time|name|names)$"#, with: "", options: .regularExpression
        )
        let sorted = candidates.sorted()

        // Three characters minimum, or "t" would "mean" title.
        if let containing = sorted.first(where: { $0 == stem })
            ?? sorted.first(where: { stem.count >= 3 && ($0.hasPrefix(stem) || stem.hasPrefix($0)) }) {
            return containing
        }

        let scored = sorted.map { ($0, editDistance(lowered, $0)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 <= max(2, lowered.count / 3) ? best.0 : nil
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}
