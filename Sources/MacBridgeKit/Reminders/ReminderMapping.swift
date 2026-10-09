//
//  ReminderMapping.swift
//  MacBridgeKit · MacBridge
//
//  Converts reminders and lists into tool results, and parses priority.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP

/// Converts `EKReminder` and reminder lists into tool result values, and parses
/// the priority spellings a model might use.
enum ReminderMapping {

    // MARK: Lists

    /// One reminder list; `incomplete_count` is included only when it was counted.
    static func list(_ cal: EKCalendar, incompleteCount: Int? = nil) -> Value {
        var out: [String: Value] = [
            "id": .string(cal.calendarIdentifier),
            "title": .string(cal.title),
            "writable": .bool(cal.allowsContentModifications),
        ]
        if let source = cal.source?.title { out["source"] = .string(source) }
        if let incompleteCount { out["incomplete_count"] = .int(incompleteCount) }
        return .object(out)
    }

    // MARK: Reminders

    /// One reminder, including its `id`. `now` decides the `overdue` flag.
    static func reminder(_ reminder: EKReminder, now: Date = Date()) -> Value {
        var out: [String: Value] = [
            "id": .string(reminder.calendarItemIdentifier),
            "title": .string(reminder.title ?? "(no title)"),
            "completed": .bool(reminder.isCompleted),
        ]

        if let cal = reminder.calendar {
            out["list"] = .string(cal.title)
            out["list_id"] = .string(cal.calendarIdentifier)
        }

        if let components = reminder.dueDateComponents {
            let hasTime = components.hour != nil
            if let due = Calendar.current.date(from: components) {
                out["due"] = .string(DateParsing.format(due, allDay: !hasTime))
                out["due_has_time"] = .bool(hasTime)

                // Must use the same rule as the `overdue` filter in
                // RemindersService.isOverdue: a date-only reminder is not late until
                // the day is over. Comparing against midnight here reported
                // "overdue": true for something due today that the filter excluded.
                let deadline = hasTime ? due : DateParsing.endOfDay(due)
                if !reminder.isCompleted && deadline < now {
                    out["overdue"] = .bool(true)
                }
            }
        }

        if let completion = reminder.completionDate {
            out["completed_at"] = .string(DateParsing.offsetDateTime.string(from: completion))
        }
        if reminder.priority != 0 {
            out["priority"] = .string(priorityLabel(reminder.priority))
            out["priority_value"] = .int(reminder.priority)
        }
        if let notes = reminder.notes, !notes.isEmpty {
            out["notes"] = .string(notes)
        }
        if let url = reminder.url?.absoluteString {
            out["url"] = .string(url)
        }
        if reminder.hasRecurrenceRules {
            out["recurring"] = .bool(true)
        }
        if let alarms = reminder.alarms, !alarms.isEmpty {
            out["alarm_count"] = .int(alarms.count)
        }
        return .object(out)
    }

    // MARK: Priority

    /// EventKit stores priority as 0 (none) and 1–9, where lower is more urgent.
    /// Reminders.app only ever shows three levels, so both spellings are accepted
    /// and the canonical values it writes (1/5/9) are the ones written back.
    static func parsePriority(_ args: Arguments, key: String = "priority") throws -> Int? {
        guard args.contains(key) else { return nil }

        if args.isExplicitNull(key) { return 0 }
        if let raw = args.optionalString(key) {
            switch raw.lowercased() {
            case "high": return 1
            case "medium", "med": return 5
            case "low": return 9
            case "none", "": return 0
            default:
                if let numeric = Int(raw), (0...9).contains(numeric) { return numeric }
                throw MacBridgeError.invalidArgument(
                    name: key,
                    reason: "expected high, medium, low, none, or 0–9"
                )
            }
        }
        if let numeric = try args.optionalInt(key) {
            guard (0...9).contains(numeric) else {
                throw MacBridgeError.invalidArgument(name: key, reason: "must be between 0 and 9")
            }
            return numeric
        }
        return nil
    }

    /// EventKit's 0–9 priority as Reminders.app shows it: 1–4 high, 5 medium, 6–9 low.
    static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        default: return "low"
        }
    }
}
