//
//  CalendarMapping.swift
//  MacBridgeKit · MacBridge
//
//  Converts EventKit calendar objects into the values tools return.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP

/// Converts EventKit objects into the `Value` shapes tools return.
///
/// Keys are snake_case to match the tool parameter names, and every field is
/// either present with a real value or omitted — never an empty string — so a
/// model does not have to distinguish `""` from "not set".
enum CalendarMapping {

    /// One calendar for `calendar_list_calendars`.
    static func calendar(_ cal: EKCalendar) -> Value {
        var out: [String: Value] = [
            "id": .string(cal.calendarIdentifier),
            "title": .string(cal.title),
            "writable": .bool(cal.allowsContentModifications),
            "type": .string(describe(cal.type)),
        ]
        if let source = cal.source?.title { out["source"] = .string(source) }
        if cal.isSubscribed { out["subscribed"] = .bool(true) }
        return .object(out)
    }

    /// One event, including the `id` every write tool takes.
    static func event(_ event: EKEvent) -> Value {
        var out: [String: Value] = [
            "title": .string(event.title ?? "(no title)"),
            "all_day": .bool(event.isAllDay),
        ]

        // eventIdentifier is the handle every write tool takes. It is optional on
        // EKEvent (unsaved events have none), so callers get told when it is absent
        // rather than silently receiving an unusable record.
        if let id = event.eventIdentifier {
            out["id"] = .string(id)
        } else {
            out["id"] = .null
            out["warning"] = .string("This occurrence has no stable identifier and cannot be edited.")
        }

        if let start = event.startDate {
            out["start"] = .string(DateParsing.format(start, allDay: event.isAllDay))
        }
        if let end = event.endDate {
            out["end"] = .string(DateParsing.format(end, allDay: event.isAllDay))
        }
        if let cal = event.calendar {
            out["calendar"] = .string(cal.title)
            out["calendar_id"] = .string(cal.calendarIdentifier)
        }
        if let location = event.location, !location.isEmpty {
            out["location"] = .string(location)
        }
        if let notes = event.notes, !notes.isEmpty {
            out["notes"] = .string(notes)
        }
        if let url = event.url?.absoluteString {
            out["url"] = .string(url)
        }
        if event.hasRecurrenceRules {
            out["recurring"] = .bool(true)
        }
        if event.isDetached {
            out["detached"] = .bool(true)
        }
        if event.status != .none {
            out["status"] = .string(describe(event.status))
        }
        if event.availability != .notSupported, event.availability != .busy {
            out["availability"] = .string(describe(event.availability))
        }
        if let organizer = event.organizer?.name {
            out["organizer"] = .string(organizer)
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            out["attendee_count"] = .int(attendees.count)
        }
        return .object(out)
    }

    // MARK: Enum descriptions
    // Stable lowercase strings rather than EventKit's raw integers, which mean
    // nothing to a model.

    static func describe(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported: return "not_supported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }
}
