//
//  CalendarTools.swift
//  MacBridgeKit · MacBridge
//
//  The eight Calendar tool definitions and their JSON schemas.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// The eight Calendar tool definitions.
///
/// Names follow a `domain_verb_object` convention: the domain prefix lets the
/// registry route by name and lets a client see at a glance which macOS app a
/// tool reaches into.
enum CalendarTools {

    static let calendarParameter = Schema.string(
        "Calendar name or id. Omit to use every calendar."
    )

    /// Every Calendar tool, in the order `tools/list` returns them.
    static func definitions() -> [Tool] {
        [
            Tool(
                name: "calendar_list_calendars",
                description: """
                    List every calendar with its id, title, account and whether it is writable. \
                    Call this first when the user names a calendar, so later tools get a real id. \
                    Reminders with due dates are not calendar events — use reminders_search_reminders for those.
                    """,
                inputSchema: Schema.object(properties: [:]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_search_events",
                description: """
                    Read calendar events in a date range, optionally filtered by text. \
                    This is the only read tool needed: for today's schedule pass start_date and end_date \
                    as "today"; for a search pass a query with a wide range. \
                    Every event includes an "id" required by the update, reschedule and cancel tools.
                    """,
                inputSchema: Schema.object(properties: [
                    "query": Schema.string("Case-insensitive text matched against title, location and notes."),
                    "start_date": Schema.string("Start of the range, inclusive. Defaults to today. \(Schema.dateFormats)"),
                    "end_date": Schema.string("End of the range, inclusive. Defaults to 7 days after start_date. \(Schema.dateFormats)"),
                    "calendars": Schema.stringList("Restrict to these calendar names or ids."),
                    "include_all_day": Schema.boolean("Include all-day events.", default: true),
                    "limit": Schema.integer("Maximum events to return.", default: 50, minimum: 1, maximum: 500),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_create_event",
                description: """
                    Create a calendar event. Only title and start are required: end defaults to one hour \
                    after start for timed events, or the same day when all_day is set.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "title": Schema.string("The event title."),
                        "start": Schema.string("When the event starts. \(Schema.dateFormats)"),
                        "end": Schema.string("When the event ends. Defaults to one hour after start. \(Schema.dateFormats)"),
                        "duration_minutes": Schema.integer("Length in minutes, as an alternative to end.", minimum: 1),
                        "all_day": Schema.boolean("Make this an all-day event."),
                        "calendar": calendarParameter,
                        "location": Schema.string("Where the event takes place."),
                        "notes": Schema.string("Free-text notes on the event."),
                        "url": Schema.string("A URL to attach, such as a meeting link."),
                        "alarm_minutes_before": Schema.integer("Add an alert this many minutes before the start.", minimum: 0),
                        "recurrence": Schema.string("Repeat frequency.", options: ["daily", "weekly", "monthly", "yearly", "none"]),
                        "recurrence_interval": Schema.integer("Repeat every N periods, e.g. 2 with weekly means fortnightly.", default: 1, minimum: 1),
                        "recurrence_count": Schema.integer("Stop after this many occurrences.", minimum: 1),
                        "recurrence_until": Schema.string("Stop repeating after this date. \(Schema.dateFormats)"),
                    ],
                    required: ["title", "start"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),

            Tool(
                name: "calendar_update_event",
                description: """
                    Change fields on an existing event. Omitted fields are left alone; passing an empty \
                    string or null for location, notes or url clears it. \
                    To move an event in time prefer calendar_reschedule_event, which preserves its duration.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "event_id": Schema.string("The event's id, from calendar_search_events."),
                        "title": Schema.string("A new title."),
                        "start": Schema.string("A new start. \(Schema.dateFormats)"),
                        "end": Schema.string("A new end. \(Schema.dateFormats)"),
                        "all_day": Schema.boolean("Switch the event between all-day and timed."),
                        "calendar": Schema.string("Move the event to this calendar, by name or id."),
                        "location": Schema.string("A new location; empty string clears it."),
                        "notes": Schema.string("New notes; empty string clears them."),
                        "url": Schema.string("A new URL; empty string clears it."),
                        "span": Schema.string(
                            "For a repeating event, whether to change this occurrence only or this and all later ones.",
                            options: ["this_event", "future_events"]
                        ),
                    ],
                    required: ["event_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_reschedule_event",
                description: """
                    Move an event to a new time, keeping its length unless new_end is given. \
                    Use this for "push my 3pm back an hour" rather than calendar_update_event.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "event_id": Schema.string("The event's id, from calendar_search_events."),
                        "new_start": Schema.string("The new start time. \(Schema.dateFormats)"),
                        "new_end": Schema.string("An explicit new end. Omit to keep the current duration. \(Schema.dateFormats)"),
                        "span": Schema.string(
                            "For a repeating event, whether to move this occurrence only or this and all later ones.",
                            options: ["this_event", "future_events"]
                        ),
                    ],
                    required: ["event_id", "new_start"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_cancel_event",
                description: """
                    Delete an event from the calendar. This cannot be undone, so confirm with the user \
                    before calling it on anything you did not just create.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "event_id": Schema.string("The event's id, from calendar_search_events."),
                        "span": Schema.string(
                            "For a repeating event, whether to delete this occurrence only or this and all later ones.",
                            options: ["this_event", "future_events"]
                        ),
                    ],
                    required: ["event_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_open_event",
                description: "Reveal an event in Calendar.app on screen, for when the user wants to see or edit it themselves.",
                inputSchema: Schema.object(
                    properties: ["event_id": Schema.string("The event's id, from calendar_search_events.")],
                    required: ["event_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "calendar_find_available_times",
                description: """
                    Find free gaps of at least duration_minutes within working hours, across the given \
                    calendars. Use this before proposing a meeting time instead of reading events and \
                    reasoning about gaps. Events marked "free" and cancelled events do not block; \
                    all-day events block their whole span.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "duration_minutes": Schema.integer("How long the slot needs to be.", default: 30, minimum: 1, maximum: 1440),
                        "start_date": Schema.string("Earliest date to consider. Defaults to now. \(Schema.dateFormats)"),
                        "end_date": Schema.string("Latest date to consider. Defaults to 7 days out. \(Schema.dateFormats)"),
                        "day_start_hour": Schema.integer("First hour of the working day, 0–23.", default: 9, minimum: 0, maximum: 23),
                        "day_end_hour": Schema.integer("Last hour of the working day, 1–24.", default: 17, minimum: 1, maximum: 24),
                        "calendars": Schema.stringList("Only treat these calendars as blocking."),
                        "limit": Schema.integer("Maximum slots to return.", default: 20, minimum: 1, maximum: 200),
                    ]
                ),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
        ]
    }
}
