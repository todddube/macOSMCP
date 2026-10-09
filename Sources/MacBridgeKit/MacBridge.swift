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
    public static let version = "0.7.0"

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
        tomorrow and +7d. Times are in the Mac's local time zone.

        Before proposing a meeting slot, call calendar_find_available_times rather than reading \
        events and reasoning about the gaps yourself.

        Two tools destroy data and cannot be undone: calendar_cancel_event and \
        reminders_delete_list, which also deletes every reminder on the list. Confirm with the user \
        before either. When a task is merely finished, call reminders_complete_reminder rather than \
        reminders_delete_reminder.
        """
}
