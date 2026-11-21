//
//  ToolMetadataTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Tool titles, the always-ask marker and output schemas against real mapping output.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// Clients may validate `structuredContent` against `outputSchema`, so these check
/// the schemas against what the mappers really produce, not what they were meant to.
@Suite("Tool metadata")
struct ToolMetadataTests {

    let tools = ToolRegistry.definitions()

    @Test("Every tool has a title, mirrored in annotations")
    func titles() {
        for tool in tools {
            #expect(!(tool.title ?? "").isEmpty, "'\(tool.name)' needs a title")
            #expect(tool.annotations.title == tool.title, "'\(tool.name)' annotations.title")
        }
        #expect(Set(ToolMetadata.titles.keys) == Set(tools.map(\.name)))
    }

    @Test("Exactly the destructive tools carry the always-ask marker")
    func alwaysAsk() {
        let marked = Set(tools.filter { $0._meta?[ToolMetadata.requiresUserInteractionKey] == .bool(true) }.map(\.name))
        #expect(marked == ToolRegistry.destructiveToolNames)
        #expect(marked == ["calendar_cancel_event", "reminders_delete_list", "reminders_delete_reminder"])
    }

    @Test("The marker reaches the wire as a top-level _meta key")
    func markerEncoding() throws {
        let tool = try #require(tools.first { $0.name == "calendar_cancel_event" })
        let data = try JSONEncoder().encode(tool)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let meta = try #require(json["_meta"] as? [String: Any])
        #expect(meta["anthropic/requiresUserInteraction"] as? Bool == true)
        #expect(json["title"] as? String == "Cancel Event")
    }

    @Test("Only the five read tools have output schemas, and they stay permissive")
    func outputSchemaShape() throws {
        let withSchema = Set(tools.filter { $0.outputSchema != nil }.map(\.name))
        #expect(withSchema == Set(ToolMetadata.outputSchemas.keys))
        #expect(withSchema.count == 5)
        for tool in tools {
            guard let schema = tool.outputSchema?.objectValue else { continue }
            #expect(schema["type"]?.stringValue == "object", "'\(tool.name)'")
            #expect(schema["additionalProperties"] == nil, "'\(tool.name)' must not forbid extra keys")
            let properties = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(properties.contains(key), "'\(tool.name)' requires undeclared '\(key)'")
            }
        }
    }

    // MARK: Real mapper output

    /// An unsaved event, as the mapper sees it before EventKit has assigned an id.
    private func fixtureEvent(store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = "Standup"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(1800)
        event.location = "Room 1"
        event.notes = "Bring notes"
        return event
    }

    @Test("Mapped events, calendars, lists and reminders satisfy their item schemas")
    func mappersMatchSchemas() throws {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Work"
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "Errands"

        let event = fixtureEvent(store: store)
        event.calendar = calendar
        event.addAlarm(EKAlarm(relativeOffset: -600))
        let bare = EKEvent(eventStore: store)   // no title, dates or calendar

        let reminder = EKReminder(eventStore: store)
        reminder.title = "Milk"
        reminder.calendar = list
        reminder.priority = 1
        reminder.dueDateComponents = DateComponents(year: 2020, month: 1, day: 2, hour: 9)
        let bareReminder = EKReminder(eventStore: store)

        let cases: [(Value, Value)] = [
            (CalendarMapping.calendar(calendar), ToolMetadata.calendarItem),
            (CalendarMapping.event(event), ToolMetadata.eventItem),
            (CalendarMapping.eventDetails(event), ToolMetadata.eventItem),
            (CalendarMapping.event(bare), ToolMetadata.eventItem),
            (ReminderMapping.list(list, incompleteCount: 3), ToolMetadata.reminderListItem),
            (ReminderMapping.list(list), ToolMetadata.reminderListItem),
            (ReminderMapping.reminder(reminder), ToolMetadata.reminderItem),
            (ReminderMapping.reminder(bareReminder), ToolMetadata.reminderItem),
        ]
        for (value, schema) in cases {
            let problems = Self.violations(of: value, against: schema)
            #expect(problems.isEmpty, "\(problems)")
        }
    }

    @Test("Result envelopes, as the services build them, satisfy the output schemas")
    func envelopesMatchSchemas() throws {
        let store = EKEventStore()
        let event = CalendarMapping.event(fixtureEvent(store: store))
        let slot: Value = .object(["start": "2026-11-20T09:00:00Z", "end": "2026-11-20T10:00:00Z", "duration_minutes": 60])
        let samples: [String: [Value]] = [
            "calendar_list_calendars": [
                .object(["calendars": .array([]), "count": 0, "default": .null]),
                .object(["calendars": .array([]), "count": 0, "default": "Work"]),
            ],
            "calendar_search_events": [
                .object(["events": .array([event]), "count": 1, "start": "a", "end": "b", "truncated": true, "total_matched": 9]),
                .object(["events": .array([]), "count": 0, "warning": "No calendars available to search."]),
                .object(["events": .array([event]), "count": 1]),
            ],
            "calendar_find_available_times": [
                .object(["slots": .array([slot]), "count": 1, "requested_duration_minutes": 30,
                         "searched_from": "a", "searched_to": "b", "working_hours": "09:00–17:00", "ignored": "x"]),
            ],
            "reminders_list_lists": [
                .object(["lists": .array([]), "count": 0]),
            ],
            "reminders_search_reminders": [
                .object(["reminders": .array([]), "count": 0, "warning": "No reminder lists available to search."]),
                .object(["reminders": .array([]), "count": 0, "total_matched": 0]),
            ],
        ]
        for (name, values) in samples {
            let schema = try #require(ToolMetadata.outputSchemas[name])
            for value in values {
                let problems = Self.violations(of: value, against: schema)
                #expect(problems.isEmpty, "\(name): \(problems)")
            }
        }
    }

    // MARK: Minimal validator

    /// Required keys present and declared property types matching, recursively.
    /// Enough to catch a schema that would make a validating client reject a result.
    static func violations(of value: Value, against schema: Value, path: String = "$") -> [String] {
        guard let schema = schema.objectValue else { return [] }
        var found: [String] = []

        if let type = schema["type"] {
            let allowed = type.arrayValue?.compactMap(\.stringValue) ?? [type.stringValue].compactMap { $0 }
            if !allowed.contains(where: { matches(value, type: $0) }) {
                return ["\(path): \(value) is not \(allowed)"]
            }
        }
        if let object = value.objectValue {
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                found.append("\(path): missing required '\(key)'")
            }
            for (key, sub) in schema["properties"]?.objectValue ?? [:] {
                if let child = object[key] { found += violations(of: child, against: sub, path: "\(path).\(key)") }
            }
        }
        if let array = value.arrayValue, let items = schema["items"] {
            for (index, element) in array.enumerated() {
                found += violations(of: element, against: items, path: "\(path)[\(index)]")
            }
        }
        return found
    }

    private static func matches(_ value: Value, type: String) -> Bool {
        switch type {
        case "object": return value.objectValue != nil
        case "array": return value.arrayValue != nil
        case "string": return value.stringValue != nil
        case "integer": return value.intValue != nil
        case "number": return value.doubleValue != nil || value.intValue != nil
        case "boolean": return value.boolValue != nil
        case "null": return value.isNull
        default: return true
        }
    }
}
