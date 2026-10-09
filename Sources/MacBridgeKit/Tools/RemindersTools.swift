//
//  RemindersTools.swift
//  MacBridgeKit · MacBridge
//
//  The ten Reminders tool definitions and their JSON schemas.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// The ten Reminders tool definitions.
///
/// Three read (list, search, open) and seven write: create, update, complete and
/// delete reminders, and create, update and delete lists.
enum RemindersTools {

    /// Every Reminders tool, in the order `tools/list` returns them.
    static func definitions() -> [Tool] {
        [
            Tool(
                name: "reminders_list_lists",
                description: """
                    List every reminder list with its id, account and count of incomplete reminders. \
                    Call this first when the user names a list, so later tools get a real id.
                    """,
                inputSchema: Schema.object(properties: [
                    "include_counts": Schema.boolean("Include the incomplete count per list.", default: true),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_search_reminders",
                description: """
                    Read reminders with any combination of filters. This one tool covers every read: \
                    all reminders on a list (pass list), a text search (pass query), what is late \
                    (pass overdue: true), what is coming up (pass due_within_days), and the full detail \
                    of one item (pass reminder_id). \
                    Completed reminders are excluded unless include_completed is true. \
                    Every reminder includes an "id" required by the update, complete and delete tools.
                    """,
                inputSchema: Schema.object(properties: [
                    "query": Schema.string("Case-insensitive text matched against title and notes."),
                    "list": Schema.stringList("Restrict to these list names or ids."),
                    "reminder_id": Schema.string("Return just this one reminder, with all its fields."),
                    "overdue": Schema.boolean("Only reminders whose due date has passed.", default: false),
                    "due_within_days": Schema.integer("Only reminders due within this many days from now.", minimum: 0),
                    "due_before": Schema.string("Only reminders due at or before this point. \(Schema.dateFormats)"),
                    "due_after": Schema.string("Only reminders due at or after this point. \(Schema.dateFormats)"),
                    "has_due_date": Schema.boolean("True for only dated reminders, false for only undated ones."),
                    "include_completed": Schema.boolean("Include reminders already completed.", default: false),
                    "limit": Schema.integer("Maximum reminders to return.", default: 50, minimum: 1, maximum: 500),
                    "offset": Schema.integer("Skip this many results, for paging.", default: 0, minimum: 0),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_create_reminder",
                description: """
                    Create a reminder. Only title is required; it lands on the user's default list \
                    unless list is given. A due date with a time also gets an alert, so it actually notifies.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "title": Schema.string("What the reminder says."),
                        "list": Schema.string("List name or id. Omit for the default list."),
                        "due": Schema.string("When it is due. Omit the time for an all-day reminder. \(Schema.dateFormats)"),
                        "notes": Schema.string("Free-text notes."),
                        "priority": Schema.string("Priority level.", options: ["high", "medium", "low", "none"]),
                        "url": Schema.string("A URL to attach."),
                        "alarm": Schema.boolean("Add an alert at the due time. Only applies when due includes a time.", default: true),
                        "recurrence": Schema.string("Repeat frequency.", options: ["daily", "weekly", "monthly", "yearly", "none"]),
                        "recurrence_interval": Schema.integer("Repeat every N periods.", default: 1, minimum: 1),
                        "recurrence_count": Schema.integer("Stop after this many occurrences.", minimum: 1),
                        "recurrence_until": Schema.string("Stop repeating after this date. \(Schema.dateFormats)"),
                    ],
                    required: ["title"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),

            Tool(
                name: "reminders_update_reminder",
                description: """
                    Change fields on an existing reminder. Omitted fields are left alone; passing an \
                    empty string or null for due, notes or url clears it. \
                    Also moves a reminder between lists when list is given.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "reminder_id": Schema.string("The reminder's id, from reminders_search_reminders."),
                        "title": Schema.string("A new title."),
                        "due": Schema.string("A new due date; empty string removes it. \(Schema.dateFormats)"),
                        "notes": Schema.string("New notes; empty string clears them."),
                        "priority": Schema.string("A new priority.", options: ["high", "medium", "low", "none"]),
                        "url": Schema.string("A new URL; empty string clears it."),
                        "list": Schema.string("Move the reminder to this list, by name or id."),
                        "completed": Schema.boolean("Mark complete or incomplete."),
                    ],
                    required: ["reminder_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_complete_reminder",
                description: """
                    Mark a reminder done, or undo that by passing completed: false. \
                    Prefer this over reminders_delete_reminder when the user says a task is finished — \
                    completing keeps the record, deleting destroys it.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "reminder_id": Schema.string("The reminder's id, from reminders_search_reminders."),
                        "completed": Schema.boolean("True to complete, false to reopen.", default: true),
                    ],
                    required: ["reminder_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_delete_reminder",
                description: """
                    Permanently delete a reminder. This cannot be undone. \
                    If the user means the task is done rather than unwanted, call \
                    reminders_complete_reminder instead.
                    """,
                inputSchema: Schema.object(
                    properties: ["reminder_id": Schema.string("The reminder's id, from reminders_search_reminders.")],
                    required: ["reminder_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_open_reminder",
                description: "Reveal a reminder in Reminders.app on screen, for when the user wants to see or edit it themselves.",
                inputSchema: Schema.object(
                    properties: ["reminder_id": Schema.string("The reminder's id, from reminders_search_reminders.")],
                    required: ["reminder_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_create_list",
                description: """
                    Create a new reminder list. It is placed in the same account as the user's default \
                    list unless source names another.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "title": Schema.string("The list name."),
                        "source": Schema.string("Account to create it in, e.g. iCloud. Omit for the default account."),
                    ],
                    required: ["title"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),

            Tool(
                name: "reminders_update_list",
                description: """
                    Rename a reminder list. This changes only the name — the reminders on it are \
                    untouched, and their ids stay valid. To move reminders between lists use \
                    reminders_update_reminder with a list argument instead.
                    """,
                inputSchema: Schema.object(
                    properties: [
                        "list": Schema.string("The list to rename, by current name or id."),
                        "title": Schema.string("The new name."),
                    ],
                    required: ["list", "title"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),

            Tool(
                name: "reminders_delete_list",
                description: """
                    Delete a reminder list and every reminder on it. This cannot be undone and is the \
                    most destructive tool here — always confirm the list name with the user first, and \
                    check its contents with reminders_search_reminders before calling.
                    """,
                inputSchema: Schema.object(
                    properties: ["list": Schema.string("The list to delete, by name or id.")],
                    required: ["list"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
        ]
    }
}
