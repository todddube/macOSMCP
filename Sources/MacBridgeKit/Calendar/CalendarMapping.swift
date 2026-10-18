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
            out["warning"] = .string("This event has no stable identifier and cannot be edited.")
        }

        // Every occurrence of a repeating event shares one id, so the id alone
        // names the series, not this occurrence. occurrence_date is the other half
        // of the handle, and the write tools take it to reach this exact one.
        if event.hasRecurrenceRules || event.isDetached, let occurrence = event.occurrenceDate {
            out["occurrence_date"] = .string(DateParsing.offsetDateTime.string(from: occurrence))
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
            if let rule = Recurrence.describe(event) { out["repeats"] = .string(rule) }
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
            // The answer to "which invites haven't I replied to", without the whole list.
            if let me = attendees.first(where: \.isCurrentUser) {
                out["my_response"] = .string(describe(me.participantStatus))
            }
        }
        return .object(out)
    }

    /// ``event(_:)`` plus who is invited, the alerts and whether it shows as busy.
    ///
    /// Kept out of the default result: a week of meetings with every attendee
    /// listed is mostly noise, and costs the model's context for nothing.
    static func eventDetails(_ event: EKEvent) -> Value {
        guard case .object(var out) = CalendarMapping.event(event) else { return CalendarMapping.event(event) }

        if event.availability != .notSupported {
            out["availability"] = .string(describe(event.availability))
        }
        if let organizer = event.organizer {
            if let email = email(of: organizer) { out["organizer_email"] = .string(email) }
            if organizer.isCurrentUser { out["organizer_is_me"] = .bool(true) }
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            out["attendees"] = .array(attendees.map(attendee))
        }
        out["alarms"] = .array((event.alarms ?? []).map(alarm))
        if let zone = event.timeZone, !event.isAllDay {
            out["time_zone"] = .string(zone.identifier)
        }
        return .object(out)
    }

    /// One invitee.
    static func attendee(_ person: EKParticipant) -> Value {
        var out: [String: Value] = [
            "response": .string(describe(person.participantStatus)),
            "role": .string(describe(person.participantRole)),
        ]
        if let name = person.name, !name.isEmpty { out["name"] = .string(name) }
        if let email = email(of: person) { out["email"] = .string(email) }
        if person.participantType != .person, person.participantType != .unknown {
            out["type"] = .string(describe(person.participantType))
        }
        if person.isCurrentUser { out["is_me"] = .bool(true) }
        return .object(out)
    }

    /// A participant's address, from its `mailto:` URL; nil for other kinds.
    static func email(of person: EKParticipant) -> String? {
        let url = person.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : (address.removingPercentEncoding ?? String(address))
    }

    /// One alert: minutes before the start, an absolute time, or a place.
    static func alarm(_ alarm: EKAlarm) -> Value {
        var out: [String: Value] = [:]
        if let place = alarm.structuredLocation?.title {
            out["location"] = .string(place)
            out["when"] = .string(alarm.proximity == .leave ? "leaving" : "arriving")
        } else if let date = alarm.absoluteDate {
            out["at"] = .string(DateParsing.offsetDateTime.string(from: date))
        } else {
            // EventKit stores "before" as a negative offset in seconds.
            out["minutes_before"] = .int(Int((-alarm.relativeOffset / 60).rounded()))
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

    static func describe(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "not_responded"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ role: EKParticipantRole) -> String {
        switch role {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "non_participant"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ type: EKParticipantType) -> String {
        switch type {
        case .unknown: return "unknown"
        case .person: return "person"
        case .room: return "room"
        case .resource: return "resource"
        case .group: return "group"
        @unknown default: return "unknown"
        }
    }

    /// The `availability` values a tool accepts, in EventKit's terms.
    static func parseAvailability(_ text: String) -> EKEventAvailability? {
        switch text.lowercased() {
        case "busy": return .busy
        case "free": return .free
        case "tentative": return .tentative
        case "unavailable", "out_of_office", "away": return .unavailable
        default: return nil
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
