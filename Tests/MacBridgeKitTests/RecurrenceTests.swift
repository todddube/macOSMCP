//
//  RecurrenceTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Repeat rules built from tool arguments, and event fields that map without a store.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// Rules are built without a store, so none of this touches data.
@Suite("Repeat rules")
struct RecurrenceTests {

    private func change(_ raw: [String: Value], existing: EKRecurrenceRule? = nil) throws -> Recurrence.Change? {
        try Recurrence.change(from: Arguments(raw), existing: existing)
    }

    private func rule(_ raw: [String: Value], existing: EKRecurrenceRule? = nil) throws -> EKRecurrenceRule {
        guard case .set(let rule) = try change(raw, existing: existing) else {
            Issue.record("expected a rule")
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        }
        return rule
    }

    private let weeklyTenTimes = EKRecurrenceRule(
        recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 10)
    )

    @Test("No repeat arguments means no change")
    func untouched() throws {
        #expect(try change(["title": .string("x")]) == nil)
    }

    @Test("none, null and blank all stop the repeat")
    func remove() throws {
        for value: Value in [.string("none"), .null, .string("")] {
            guard case .remove = try change(["recurrence": value], existing: weeklyTenTimes) else {
                Issue.record("\(value) should stop the repeat")
                continue
            }
        }
    }

    @Test("Changing only the interval keeps the frequency and end")
    func keepsTheRest() throws {
        let updated = try rule(["recurrence_interval": .int(2)], existing: weeklyTenTimes)
        #expect(updated.frequency == .weekly)
        #expect(updated.interval == 2)
        #expect(updated.recurrenceEnd?.occurrenceCount == 10)
    }

    @Test("A new frequency starts afresh rather than keeping an end chosen for the old one")
    func newFrequency() throws {
        let updated = try rule(["recurrence": .string("monthly")], existing: weeklyTenTimes)
        #expect(updated.frequency == .monthly)
        #expect(updated.interval == 1)
        #expect(updated.recurrenceEnd == nil)
    }

    @Test("A null end repeats forever")
    func forever() throws {
        let updated = try rule(["recurrence_count": .null], existing: weeklyTenTimes)
        #expect(updated.recurrenceEnd == nil)
    }

    @Test("A date-only end includes that whole day")
    func untilWholeDay() throws {
        let updated = try rule(["recurrence": .string("daily"), "recurrence_until": .string("2026-11-01")])
        let end = try #require(updated.recurrenceEnd?.endDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: end)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 1)
        #expect(parts.hour == 23)
    }

    @Test("Ending a repeat on something that doesn't repeat asks how often")
    func needsFrequency() {
        #expect(throws: MacBridgeError.self) { try change(["recurrence_count": .int(3)]) }
    }

    @Test("A frequency that isn't one of the four is refused")
    func unknownFrequency() {
        #expect(throws: MacBridgeError.self) { try change(["recurrence": .string("fortnightly")]) }
    }

    @Test("Changing the count of a weekly-on-days repeat keeps the days")
    func keepsWeekdays() throws {
        let monWedFri = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [.init(.monday), .init(.wednesday), .init(.friday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        let updated = try rule(["recurrence_count": .int(10)], existing: monWedFri)
        #expect(updated.daysOfTheWeek?.map(\.dayOfTheWeek) == [.monday, .wednesday, .friday])
        #expect(Recurrence.describe(updated) == "every week on Mon, Wed, Fri, 10 times")
    }

    @Test("A month's nth weekday reads as such")
    func describesNthWeekday() {
        let secondTuesday = EKRecurrenceRule(
            recurrenceWith: .monthly, interval: 1,
            daysOfTheWeek: [.init(.tuesday, weekNumber: 2)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        #expect(Recurrence.describe(secondTuesday) == "every month on 2nd Tue")
    }

    @Test("Splitting a series that ends after a count asks for the end again")
    func splitRestatesCount() throws {
        #expect(throws: MacBridgeError.self) {
            try Recurrence.change(
                from: Arguments(["recurrence_interval": .int(2)]), existing: weeklyTenTimes, splitsSeries: true
            )
        }
        let restated = try Recurrence.change(
            from: Arguments(["recurrence_interval": .int(2), "recurrence_count": .int(3)]),
            existing: weeklyTenTimes, splitsSeries: true
        )
        guard case .set(let updated) = restated else { Issue.record("expected a rule"); return }
        #expect(updated.recurrenceEnd?.occurrenceCount == 3)
    }

    @Test("Ordinals read naturally, from the end too")
    func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23].map(Recurrence.ordinal)
            == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd"])
        #expect(Recurrence.ordinal(-1) == "last")
        #expect(Recurrence.ordinal(-2) == "2nd last")
    }

    @Test("An end date that isn't text doesn't count as restating the end")
    func nonTextUntil() {
        #expect(throws: MacBridgeError.self) {
            try Recurrence.change(
                from: Arguments(["recurrence_until": .int(20261101)]), existing: weeklyTenTimes, splitsSeries: true
            )
        }
    }

    @Test("A repeat that isn't text is refused, not taken as none")
    func nonTextRecurrence() {
        #expect(throws: MacBridgeError.self) { try change(["recurrence": .int(2)], existing: weeklyTenTimes) }
        #expect(throws: MacBridgeError.self) { try change(["recurrence": .bool(true)], existing: weeklyTenTimes) }
    }

    @Test("Results describe the repeat in words")
    func describe() {
        #expect(Recurrence.describe(weeklyTenTimes) == "every week, 10 times")
        #expect(Recurrence.describe(EKRecurrenceRule(recurrenceWith: .daily, interval: 3, end: nil)) == "every 3 days")
    }
}

/// The event fields that don't need a store.
@Suite("Event detail mapping")
struct EventDetailMappingTests {

    @Test("Availability accepts the spellings a model reaches for")
    func availability() {
        #expect(CalendarMapping.parseAvailability("Free") == .free)
        #expect(CalendarMapping.parseAvailability("out_of_office") == .unavailable)
        #expect(CalendarMapping.parseAvailability("maybe") == nil)
    }

    @Test("Alerts read as minutes before, or a time")
    func alarms() {
        #expect(CalendarMapping.alarm(EKAlarm(relativeOffset: -900)) == .object(["minutes_before": .int(15)]))
        #expect(CalendarMapping.alarm(EKAlarm(relativeOffset: 0)) == .object(["minutes_before": .int(0)]))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CalendarMapping.alarm(EKAlarm(absoluteDate: at))
            == .object(["at": .string(DateParsing.offsetDateTime.string(from: at))]))
    }
}
