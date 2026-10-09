//
//  CalendarResolution.swift
//  MacBridgeKit · MacBridge
//
//  Resolves calendars and reminder lists by name or identifier.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation

/// Shared calendar/list lookup used by both domains.
///
/// Models refer to calendars by human name far more often than by identifier,
/// so every resolver accepts either and matches names case-insensitively.
enum CalendarResolution {

    /// Event calendars, sorted by title.
    ///
    /// No filtering is needed for Calendar.app's "Scheduled Reminders" view of dated
    /// reminders: EventKit does not return it as an event calendar (checked on
    /// macOS 27), so reminders are never double-reported as events. An earlier
    /// filter matched it by its English title, which did nothing under EventKit and
    /// could never have matched a localized title anyway.
    static func eventCalendars(in store: EKEventStore) -> [EKCalendar] {
        store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reminder lists, sorted by title.
    static func reminderCalendars(in store: EKEventStore) -> [EKCalendar] {
        store.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Resolve one calendar by identifier or title.
    static func resolve(
        identifier: String,
        among candidates: [EKCalendar],
        kind: String
    ) throws -> EKCalendar {
        if let byID = candidates.first(where: { $0.calendarIdentifier == identifier }) {
            return byID
        }
        if let byTitle = candidates.first(where: { $0.title.caseInsensitiveCompare(identifier) == .orderedSame }) {
            return byTitle
        }
        throw MacBridgeError.notFound(kind: kind, identifier: identifier)
    }

    /// Resolve the subset a query should search: named ones, or all of them.
    static func resolveSubset(
        names: [String]?,
        among candidates: [EKCalendar],
        kind: String
    ) throws -> [EKCalendar] {
        guard let names, !names.isEmpty else { return candidates }
        return try names.map { try resolve(identifier: $0, among: candidates, kind: kind) }
    }

    /// Throw `notWritable` for subscribed, shared read-only and similar calendars,
    /// before EventKit fails the save with a less useful error.
    static func requireWritable(_ calendar: EKCalendar, kind: String) throws {
        guard calendar.allowsContentModifications else {
            throw MacBridgeError.notWritable(kind: kind, identifier: calendar.title)
        }
    }
}
