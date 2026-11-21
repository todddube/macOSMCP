//
//  ToolMetadata.swift
//  MacBridgeKit · MacBridge
//
//  Display titles, the always-ask marker and output schemas layered onto the tool definitions.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// What a client's tool list shows beyond names and input schemas.
///
/// Kept apart from the definitions so those stay readable as a spec of the inputs,
/// and applied once by ``ToolRegistry``.
enum ToolMetadata {

    /// The `_meta` key that makes Claude Code prompt for a tool even in permissive modes.
    static let requiresUserInteractionKey = "anthropic/requiresUserInteraction"

    /// Human-readable names, shown in place of the snake_case identifier.
    static let titles: [String: String] = [
        "calendar_list_calendars": "List Calendars",
        "calendar_search_events": "Search Events",
        "calendar_create_event": "Create Event",
        "calendar_update_event": "Update Event",
        "calendar_reschedule_event": "Reschedule Event",
        "calendar_cancel_event": "Cancel Event",
        "calendar_open_event": "Open Event",
        "calendar_find_available_times": "Find Available Times",
        "reminders_list_lists": "List Reminder Lists",
        "reminders_search_reminders": "Search Reminders",
        "reminders_create_reminder": "Create Reminder",
        "reminders_update_reminder": "Update Reminder",
        "reminders_complete_reminder": "Complete Reminder",
        "reminders_delete_reminder": "Delete Reminder",
        "reminders_open_reminder": "Open Reminder",
        "reminders_create_list": "Create Reminder List",
        "reminders_update_list": "Update Reminder List",
        "reminders_delete_list": "Delete Reminder List",
    ]

    /// `tool` with its title, always-ask marker and output schema filled in.
    ///
    /// The marker follows `destructiveHint`, the same flag ``AccessPolicy``'s
    /// confirmation set is read from, so the two cannot disagree.
    static func decorated(_ tool: Tool) -> Tool {
        var annotations = tool.annotations
        let title = titles[tool.name] ?? tool.title
        annotations.title = title

        var meta = tool._meta
        if tool.annotations.destructiveHint == true {
            var fields = meta?.fields ?? [:]
            fields[requiresUserInteractionKey] = .bool(true)
            meta = Metadata(additionalFields: fields)
        }

        return Tool(
            name: tool.name,
            title: title,
            description: tool.description,
            inputSchema: tool.inputSchema,
            annotations: annotations,
            outputSchema: tool.outputSchema ?? outputSchemas[tool.name],
            icons: tool.icons,
            _meta: meta
        )
    }

    // MARK: Output schemas

    /// Schemas for the read tools.
    ///
    /// Clients may validate `structuredContent` against these, so each is
    /// deliberately permissive: top-level keys and item shapes are described, only
    /// keys present on every successful result are required, and nothing sets
    /// `additionalProperties: false`. Every tool returns an object, so each result
    /// goes out as `structuredContent` as an outputSchema needs.
    static let outputSchemas: [String: Value] = [
        "calendar_list_calendars": Schema.object(
            properties: [
                "calendars": Schema.array("Every calendar.", items: calendarItem),
                "count": Schema.integer("How many calendars."),
                "default": Schema.typed("string", "null", description: "Title of the calendar new events go on, if there is one."),
            ],
            required: ["calendars", "count"]
        ),
        "calendar_search_events": Schema.object(
            properties: [
                "events": Schema.array("Matching events, soonest first.", items: eventItem),
                "count": Schema.integer("How many events are in this result."),
                "start": Schema.string("Start of the range searched."),
                "end": Schema.string("End of the range searched."),
                "query": Schema.string("The text filter, when one was given."),
                "calendars_searched": Schema.array("Calendars searched, when some were named.", items: .object(["type": .string("string")])),
                "truncated": Schema.boolean("True when more events matched than limit allowed."),
                "total_matched": Schema.integer("How many events matched before limit applied."),
                "warning": Schema.string("A note about the result, such as a narrowed range."),
            ],
            required: ["events", "count"]
        ),
        "calendar_find_available_times": Schema.object(
            properties: [
                "slots": Schema.array("Free gaps within working hours, soonest first.", items: Schema.object(
                    properties: [
                        "start": Schema.string("When the gap starts."),
                        "end": Schema.string("When the gap ends."),
                        "duration_minutes": Schema.integer("Length of the gap."),
                    ],
                    required: ["start", "end", "duration_minutes"]
                )),
                "count": Schema.integer("How many slots."),
                "requested_duration_minutes": Schema.integer("The duration asked for."),
                "searched_from": Schema.string("Start of the range searched."),
                "searched_to": Schema.string("End of the range searched."),
                "working_hours": Schema.string("The working day applied, such as 09:00–17:00."),
                "ignored": Schema.string("Which subscribed calendars' all-day events were not counted as busy."),
                "warning": Schema.string("A note about the result, such as a narrowed range."),
            ],
            required: ["slots", "count"]
        ),
        "reminders_list_lists": Schema.object(
            properties: [
                "lists": Schema.array("Every reminder list.", items: reminderListItem),
                "count": Schema.integer("How many lists."),
                "default": Schema.string("Title of the list new reminders go on, when there is one."),
            ],
            required: ["lists", "count"]
        ),
        "reminders_search_reminders": Schema.object(
            properties: [
                "reminders": Schema.array("Matching reminders, soonest due first.", items: reminderItem),
                "count": Schema.integer("How many reminders are in this result."),
                "total_matched": Schema.integer("How many reminders matched before limit and offset applied."),
                "offset": Schema.integer("The offset applied, when not zero."),
                "query": Schema.string("The text filter, when one was given."),
                "lists_searched": Schema.array("Lists searched, when some were named.", items: .object(["type": .string("string")])),
                "truncated": Schema.boolean("True when more reminders matched than this result holds."),
                "warning": Schema.string("A note about the result."),
            ],
            required: ["reminders", "count"]
        ),
    ]

    static let calendarItem = Schema.object(
        properties: [
            "id": Schema.string("The calendar's id."),
            "title": Schema.string("The calendar's name."),
            "writable": Schema.boolean("Whether events can be added or changed."),
            "type": Schema.string("local, caldav, exchange, subscription, birthday or unknown."),
            "source": Schema.string("The account the calendar belongs to."),
            "subscribed": Schema.boolean("True for a subscribed calendar."),
        ],
        required: ["id", "title", "writable", "type"]
    )

    /// An event as search returns it; the `attendees`, `alarms` and similar keys
    /// appear only with details.
    static let eventItem = Schema.object(
        properties: [
            "id": Schema.typed("string", "null", description: "The id the write tools take; null when the event has none."),
            "title": Schema.string("The event title."),
            "all_day": Schema.boolean("Whether the event is all-day."),
            "occurrence_date": Schema.string("Which occurrence of a repeating event this is."),
            "start": Schema.string("When the event starts."),
            "end": Schema.string("When the event ends."),
            "calendar": Schema.string("Name of the calendar the event is on."),
            "calendar_id": Schema.string("Id of that calendar."),
            "location": Schema.string("Where the event takes place."),
            "notes": Schema.string("The event's notes."),
            "url": Schema.string("The attached URL."),
            "recurring": Schema.boolean("True when the event repeats."),
            "repeats": Schema.string("How the event repeats."),
            "detached": Schema.boolean("True for an occurrence changed apart from its series."),
            "status": Schema.string("none, confirmed, tentative, canceled or unknown."),
            "availability": Schema.string("busy, free, tentative, unavailable or not_supported."),
            "organizer": Schema.string("Who organized the event."),
            "attendee_count": Schema.integer("How many people are invited."),
            "my_response": Schema.string("The user's reply to the invitation."),
            "warning": Schema.string("A note about the event."),
            "organizer_email": Schema.string("The organizer's address, with details."),
            "organizer_is_me": Schema.boolean("True when the user organized it, with details."),
            "attendees": Schema.array("Who is invited, with details.", items: .object(["type": .string("object")])),
            "alarms": Schema.array("The event's alerts, with details.", items: .object(["type": .string("object")])),
            "time_zone": Schema.string("The event's time zone: with details, or whenever it isn't the Mac's."),
        ],
        required: ["id", "title", "all_day"]
    )

    static let reminderListItem = Schema.object(
        properties: [
            "id": Schema.string("The list's id."),
            "title": Schema.string("The list's name."),
            "writable": Schema.boolean("Whether reminders can be added or changed."),
            "source": Schema.string("The account the list belongs to."),
            "incomplete_count": Schema.integer("How many reminders are not completed."),
        ],
        required: ["id", "title", "writable"]
    )

    static let reminderItem = Schema.object(
        properties: [
            "id": Schema.string("The id the write tools take."),
            "title": Schema.string("The reminder title."),
            "completed": Schema.boolean("Whether the reminder is done."),
            "list": Schema.string("Name of the list it is on."),
            "list_id": Schema.string("Id of that list."),
            "due": Schema.string("When it is due."),
            "due_has_time": Schema.boolean("False when the due date has no time of day."),
            "overdue": Schema.boolean("True when it is past due and not completed."),
            "completed_at": Schema.string("When it was completed."),
            "priority": Schema.string("none, high, medium or low."),
            "priority_value": Schema.integer("EventKit's 0 to 9 priority."),
            "notes": Schema.string("The reminder's notes."),
            "url": Schema.string("The attached URL."),
            "recurring": Schema.boolean("True when it repeats."),
            "repeats": Schema.string("How it repeats."),
            "alarm_count": Schema.integer("How many alerts it has."),
        ],
        required: ["id", "title", "completed"]
    )
}
