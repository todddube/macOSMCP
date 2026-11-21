//
//  ResourceCatalog.swift
//  MacBridgeKit · MacBridge
//
//  The MCP resources: read-only views of the agenda and reminders a client can attach.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// The MCP resources MacBridge offers: today's agenda, the week ahead, overdue
/// reminders, and any one reminder list through a URI template. Claude Code attaches them with an
/// @-mention (`@macbridge:macbridge://agenda/today`); Claude Desktop from its
/// attachment menu.
///
/// Each resource is read by running the read tools, through whatever runs tools
/// for this process: in the shim that is the bridge, so a resource read gets the
/// same access checks and activity log as the calls it stands for, and needs
/// nothing new from the app. The content is those tools' JSON, gathered into one
/// object.
public enum ResourceCatalog {

    /// Runs one tool and returns its result, as `ToolBackend.callTool` does.
    public typealias CallTool = @Sendable (_ name: String, _ arguments: [String: Value]?) async throws -> Value

    /// A URI that isn't one of ours. A well-formed list URI naming a list that
    /// doesn't exist is not this error: that fails in the tool, as `notFound`.
    public enum ResourceError: LocalizedError, Equatable {
        case unknownResource(String)

        public var errorDescription: String? {
            switch self {
            case .unknownResource(let uri):
                "No resource at '\(uri)'. Use resources/list, or \(listTemplate) with a list id."
            }
        }

        /// The spec's code for a resource that doesn't exist.
        public static let code = -32002
    }

    /// Every resource is the read tools' JSON, so every one has this type.
    public static let mimeType = "application/json"

    static let todayURI = "macbridge://agenda/today"
    static let weekURI = "macbridge://agenda/week"
    static let overdueURI = "macbridge://reminders/overdue"
    static let listPrefix = "macbridge://reminders/list/"
    static let listTemplate = "macbridge://reminders/list/{list_id}"

    /// The resources that are always there, in the order `resources/list` returns them.
    public static let fixed: [Resource] = [
        Resource(
            name: "agenda-today", uri: todayURI, title: "Today's Agenda",
            description: "Today's events, the reminders due today, and overdue reminders.",
            mimeType: mimeType
        ),
        Resource(
            name: "agenda-week", uri: weekURI, title: "This Week",
            description: "Events and reminders due over the seven days starting today.",
            mimeType: mimeType
        ),
        Resource(
            name: "reminders-overdue", uri: overdueURI, title: "Overdue Reminders",
            description: "Every incomplete reminder whose due date has passed, on every list.",
            mimeType: mimeType
        ),
    ]

    /// One reminder list's incomplete reminders, by list id.
    public static let templates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: listTemplate, name: "reminder-list", title: "Reminder List",
            description: "The incomplete reminders on one list. Ids come from reminders_list_lists.",
            mimeType: mimeType
        ),
    ]

    /// Everything for `resources/list`: the fixed resources only. A list's own
    /// resource is reached through ``templates`` with an id from
    /// `reminders_list_lists`. Listing the lists here would read Reminders on every
    /// connect, which on a fresh install puts up the permission prompt before the
    /// user has asked for anything, and can outlast the client's request timeout.
    public static var resources: [Resource] { fixed }

    /// The resource at `uri`, as JSON text.
    ///
    /// - Throws: ``ResourceError/unknownResource(_:)`` for a URI that isn't ours,
    ///   or whatever the underlying tool throws (no access, list not found).
    public static func read(_ uri: String, call: CallTool, now: Date = Date(),
                            calendar: Calendar = .autoupdatingCurrent) async throws -> Resource.Content {
        let content: Value
        switch uri {
        case todayURI:
            let today = day(now, calendar: calendar)
            let dueToday = try await call("reminders_search_reminders", [
                "due_after": .string(today), "due_before": .string(today), "limit": .int(200),
            ])
            content = .object([
                "date": .string(today),
                "events": try await call("calendar_search_events", [
                    "start_date": .string(today), "end_date": .string(today), "limit": .int(200),
                ]),
                "reminders_due": dueToday,
                // A timed reminder due earlier today is in both searches; it's
                // listed once, as due today.
                "overdue": dropping(try await call("reminders_search_reminders", [
                    "overdue": .bool(true), "limit": .int(200),
                ]), alsoIn: dueToday),
            ])

        case weekURI:
            let first = day(now, calendar: calendar)
            let last = day(calendar.date(byAdding: .day, value: 6, to: now) ?? now, calendar: calendar)
            content = .object([
                "from": .string(first),
                "through": .string(last),
                "events": try await call("calendar_search_events", [
                    "start_date": .string(first), "end_date": .string(last), "limit": .int(500),
                ]),
                "reminders_due": try await call("reminders_search_reminders", [
                    "due_after": .string(first), "due_before": .string(last), "limit": .int(500),
                ]),
            ])

        case overdueURI:
            content = try await call("reminders_search_reminders", ["overdue": .bool(true), "limit": .int(500)])

        default:
            guard let id = listID(from: uri) else { throw ResourceError.unknownResource(uri) }
            content = try await call("reminders_search_reminders", ["list": .array([.string(id)]), "limit": .int(500)])
        }
        return .text(JSONText.encode(content), uri: uri, mimeType: mimeType)
    }

    /// `search` without the reminders also in `other`, matched by id, with its count
    /// adjusted. Anything that isn't a search result is returned unchanged.
    static func dropping(_ search: Value, alsoIn other: Value) -> Value {
        guard var object = search.objectValue, case .array(let reminders)? = object["reminders"],
              case .array(let others)? = other.objectValue?["reminders"] else { return search }
        let seen = Set(others.compactMap { $0.objectValue?["id"]?.stringValue })
        let kept = reminders.filter { !seen.contains($0.objectValue?["id"]?.stringValue ?? "") }
        object["reminders"] = .array(kept)
        if object["count"] != nil { object["count"] = .int(kept.count) }
        return .object(object)
    }

    // MARK: - URIs and dates

    /// The per-list URI for `id`. Percent-encoded, `/` included, so an id can't add a
    /// path segment and ``listID(from:)`` gets the same id back.
    static func listURI(id: String) -> String {
        listPrefix + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id)
    }

    /// The list id in a per-list URI, or nil when `uri` isn't one.
    static func listID(from uri: String) -> String? {
        guard uri.hasPrefix(listPrefix) else { return nil }
        let encoded = String(uri.dropFirst(listPrefix.count))
        guard !encoded.isEmpty, !encoded.contains("/"),
              let id = encoded.removingPercentEncoding, !id.isEmpty else { return nil }
        return id
    }

    /// `date` as YYYY-MM-DD in `calendar`'s time zone, the form the tools read as a
    /// whole day. Always Gregorian, as the tools parse it: the user's own calendar
    /// may be Buddhist or Japanese, whose years would name the wrong day.
    static func day(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
