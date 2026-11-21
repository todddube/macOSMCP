//
//  PromptCatalog.swift
//  MacBridgeKit · MacBridge
//
//  The MCP prompts: ready-made requests that walk a model through the tools.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// The MCP prompts MacBridge offers. Claude Code lists them as slash commands
/// (`/mcp__macbridge__daily-agenda`), Claude Desktop in its attachment menu.
///
/// A prompt is only text: it tells the model which tools to call and how to
/// present the answer, and the model then makes those calls as usual, through
/// the same policy and confirmation as any other call. So prompts need no
/// EventKit access and are answered by whichever process serves MCP.
public enum PromptCatalog {

    /// A `prompts/get` for a name that isn't one of ``definitions``.
    public enum PromptError: LocalizedError, Equatable {
        case unknownPrompt(String)

        public var errorDescription: String? {
            switch self {
            case .unknownPrompt(let name):
                "No prompt named '\(name)'. Available: \(PromptCatalog.names.joined(separator: ", "))."
            }
        }
    }

    /// Every prompt, in the order `prompts/list` returns them.
    public static let definitions: [Prompt] = [
        Prompt(
            name: "daily-agenda",
            title: "Daily Agenda",
            description: "One day's events and the reminders due that day, in order, with free gaps called out.",
            arguments: [
                .init(name: "date", title: "Date",
                      description: "The day to cover: today, tomorrow, or YYYY-MM-DD. Defaults to today.",
                      required: false),
            ]
        ),
        Prompt(
            name: "plan-my-week",
            title: "Plan My Week",
            description: "The next seven days at a glance: busy days, free blocks, deadlines, and what to schedule where.",
            arguments: [
                .init(name: "start", title: "Start",
                      description: "The first day of the week to plan: today, tomorrow, +7d, or YYYY-MM-DD. Defaults to today.",
                      required: false),
                .init(name: "focus", title: "Focus",
                      description: "Something to make room for, such as \"two hours of deep work a day\".",
                      required: false),
            ]
        ),
        Prompt(
            name: "review-overdue",
            title: "Review Overdue",
            description: "Every overdue reminder, grouped by list, with a suggestion for each: do, reschedule or drop.",
            arguments: [
                .init(name: "list", title: "List",
                      description: "Only review this reminder list, by name. Defaults to every list.",
                      required: false),
            ]
        ),
    ]

    /// Prompt names, for error messages and tests.
    public static var names: [String] { definitions.map(\.name) }

    /// The messages for one prompt, with its arguments filled in.
    ///
    /// Arguments are free text from the user; they are quoted into the request,
    /// never trusted as dates here. The tools parse and validate them on the call.
    ///
    /// - Throws: ``PromptError/unknownPrompt(_:)`` when `name` isn't in ``definitions``.
    public static func messages(for name: String, arguments: [String: String]?) throws -> GetPrompt.Result {
        let arguments = (arguments ?? [:]).mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ key: String) -> String? { arguments[key].flatMap { $0.isEmpty ? nil : $0 } }

        let text: String
        switch name {
        case "daily-agenda":
            text = dailyAgenda(date: value("date") ?? "today")
        case "plan-my-week":
            text = planMyWeek(start: value("start") ?? "today", focus: value("focus"))
        case "review-overdue":
            text = reviewOverdue(list: value("list"))
        default:
            throw PromptError.unknownPrompt(name)
        }
        let description = definitions.first { $0.name == name }?.description
        return GetPrompt.Result(description: description, messages: [.user(.text(text: text))])
    }

    // MARK: - Prompt text

    private static func dailyAgenda(date: String) -> String {
        """
        Give me my agenda for \(quoted(date)), using MacBridge.

        1. Call calendar_search_events with start_date and end_date both set to \(quoted(date)).
        2. Call reminders_search_reminders with due_after and due_before covering that same day, \
        and, if the day is today, again with overdue: true.

        Then write one agenda in time order: all-day events first, then each timed event with \
        its start and end, location if any, and the reminders due that day where their times fall. \
        Point out any gap of an hour or more, and any events that overlap. List overdue reminders \
        separately at the end. Keep it short; don't change anything.
        """
    }

    private static func planMyWeek(start: String, focus: String?) -> String {
        var text = """
            Help me plan the seven days starting \(quoted(start)), using MacBridge.

            1. Call calendar_search_events with start_date \(quoted(start)) and no end_date \
            (it covers seven days).
            2. Call calendar_find_available_times with start_date \(quoted(start)) and \
            duration_minutes 60, for the free blocks in working hours.
            3. Call reminders_search_reminders twice: once with due_after \(quoted(start)) and \
            due_before the sixth day after it, as YYYY-MM-DD, for what's due that week; and once \
            with overdue: true for what's already late. Don't count a reminder in both.

            Then give me, day by day: how busy it is, the longest free block, and the deadlines \
            that land on it. Flag overloaded days and conflicts. Suggest where the overdue and \
            upcoming reminders could get done.
            """
        if let focus {
            text += "\n\nAlso make room for this: \(quoted(focus)). Propose specific free blocks for it."
        }
        text += """


            Don't create, move or delete anything until I say which suggestions I want. \
            Then use calendar_create_event or reminders_update_reminder for just those.
            """
        return text
    }

    private static func reviewOverdue(list: String?) -> String {
        let scope = list.map { "on the \(quoted($0)) list" } ?? "on every list"
        let listArgument = list.map { " and list [\(quoted($0))]" } ?? ""
        return """
            Review my overdue reminders \(scope), using MacBridge.

            Call reminders_search_reminders with overdue: true\(listArgument). Group what comes \
            back by list, oldest first, and for each say how late it is and suggest one of: do it \
            today, a new due date, or drop it.

            Don't change anything until I answer. Then, for the ones I pick: \
            reminders_update_reminder with a new due for rescheduling, and \
            reminders_complete_reminder for anything I say is done or no longer needed. \
            Don't delete reminders; completing keeps the record.
            """
    }

    /// Quotes user text into a prompt, so it reads as data within the request: on
    /// one line, so it can't pass for a step of its own, and unable to close its quotes.
    static func quoted(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\"\(oneLine.replacingOccurrences(of: "\"", with: "'"))\""
    }
}
