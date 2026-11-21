//
//  MacBridge.swift
//  MacBridgeKit · MacBridge
//
//  Shared identity: name, version, and the instructions MCP clients receive.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Identity shared by the app, the CLI and the eventual client configs.
public enum MacBridge {
    public static let serverName = "macbridge"
    /// Must match MARKETING_VERSION in project.yml; `VersionTests` fails if they drift.
    public static let version = "1.9.0"

    /// The day `version` was cut, as YYYY-MM-DD. Bump it with `version`; `VersionTests`
    /// checks it against the newest entry in the README's version history.
    public static let releaseDate = "2026-11-20"

    /// The release date for people, in their locale: "November 20, 2026".
    /// Read and written in UTC, so no time zone moves it to another day. Falls back
    /// to the raw YYYY-MM-DD if it doesn't parse.
    public static var releaseDateText: String {
        let utc = TimeZone(identifier: "UTC")!
        let parts = releaseDate.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return releaseDate }
        var style = Date.FormatStyle.dateTime.year().month(.wide).day()
        style.timeZone = utc
        return day.formatted(style)
    }

    /// Version and release date together, as people see it: "1.9.0 · November 20, 2026".
    public static var versionWithDate: String {
        "\(version) · \(releaseDateText)"
    }

    /// Sent to clients as MCP `instructions`: the orientation a model gets
    /// before it has called anything.
    ///
    /// Kept short on purpose — the per-tool descriptions carry the detail, and
    /// duplicating them here only invites the two to drift apart.
    public static let instructions = """
        Read and manage the user's macOS Calendar and Reminders on this Mac, through EventKit.

        Start by listing: calendar_list_calendars or reminders_list_lists, so you refer to real \
        calendars and lists. Read with calendar_search_events and reminders_search_reminders — each \
        is a single tool covering today's schedule, text search, overdue items and upcoming items \
        through its parameters. Both return an "id" per item, which every write tool requires.

        Dates accept YYYY-MM-DD, YYYY-MM-DDTHH:MM:SS, ISO-8601, or relative values like today, \
        tomorrow and +7d. Times are in the Mac's local time zone, or an event's time_zone when given.

        Before proposing a meeting slot, call calendar_find_available_times rather than reading \
        events and reasoning about the gaps yourself.

        Two tools destroy data and cannot be undone: calendar_cancel_event and \
        reminders_delete_list, which also deletes every reminder on the list. Confirm with the user \
        before either. When a task is merely finished, call reminders_complete_reminder rather than \
        reminders_delete_reminder.
        """
}
