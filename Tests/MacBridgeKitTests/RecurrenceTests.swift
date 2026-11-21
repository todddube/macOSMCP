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

/// Weekdays, nth weekdays, positions and days of the month: parsing, how they fit
/// each frequency, how an update merges them, and how results describe them.
@Suite("Repeat day patterns")
struct RecurrencePatternTests {

    /// The rule a call builds, failing the test when it builds none.
    private func rule(
        _ raw: [String: Value],
        existing: EKRecurrenceRule? = nil,
        start: Date? = nil
    ) throws -> EKRecurrenceRule {
        guard case .set(let rule) = try Recurrence.change(from: Arguments(raw), existing: existing, start: start) else {
            Issue.record("expected a rule")
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        }
        return rule
    }

    /// The argument named by the `invalidArgument` a call throws, and its reason.
    private func refusal(
        _ raw: [String: Value],
        existing: EKRecurrenceRule? = nil
    ) -> (name: String, reason: String)? {
        do {
            _ = try Recurrence.change(from: Arguments(raw), existing: existing)
        } catch MacBridgeError.invalidArgument(let name, let reason) {
            return (name, reason)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        return nil
    }

    private func days(_ rule: EKRecurrenceRule) -> [String] {
        (rule.daysOfTheWeek ?? []).map(Recurrence.describe)
    }

    private func numbers(_ values: [NSNumber]?) -> [Int] { (values ?? []).map(\.intValue) }

    private func monthly(
        days: [EKRecurrenceDayOfWeek]? = nil,
        monthDays: [Int]? = nil,
        positions: [Int]? = nil,
        count: Int? = nil
    ) -> EKRecurrenceRule {
        EKRecurrenceRule(
            recurrenceWith: .monthly, interval: 1,
            daysOfTheWeek: days,
            daysOfTheMonth: monthDays?.map { NSNumber(value: $0) },
            monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: positions?.map { NSNumber(value: $0) },
            end: count.map { EKRecurrenceEnd(occurrenceCount: $0) }
        )
    }

    // MARK: Parsing weekdays

    @Test("Weekday names, full or three-letter, in any case", arguments: [
        ("monday", EKWeekday.monday), ("Mon", .monday), ("TUESDAY", .tuesday), ("tue", .tuesday),
        ("Wednesday", .wednesday), ("wed", .wednesday), ("thursday", .thursday), ("thu", .thursday),
        ("friday", .friday), ("FRI", .friday), ("saturday", .saturday), ("sat", .saturday),
        ("sunday", .sunday), ("Sun", .sunday),
    ])
    func weekdayNames(text: String, day: EKWeekday) throws {
        let parsed = try Recurrence.weekday(from: text)
        #expect(parsed.dayOfTheWeek == day)
        #expect(parsed.weekNumber == 0)
    }

    @Test("Ordinal prefixes map to week numbers", arguments: [
        ("1st mon", 1), ("first monday", 1), ("2nd tuesday", 2), ("2 tue", 2), ("3rd wed", 3),
        ("4th thursday", 4), ("5th fri", 5), ("fifth friday", 5), ("last friday", -1), ("-1 fri", -1),
        ("second-to-last fri", -2), ("2nd last friday", -2), ("-2 friday", -2), ("Last  Friday", -1),
    ])
    func ordinalPrefixes(text: String, week: Int) throws {
        #expect(try Recurrence.weekday(from: text).weekNumber == week)
    }

    @Test("Not a weekday, or an ordinal out of range, is refused with advice", arguments: [
        "funday", "tues", "6th monday", "0 monday", "-3 friday", "3th monday", "", "2nd",
    ])
    func badWeekdays(text: String) {
        do {
            _ = try Recurrence.weekday(from: text)
            Issue.record("'\(text)' should be refused")
        } catch MacBridgeError.invalidArgument(let name, let reason) {
            #expect(name == "recurrence_days")
            #expect(reason.contains("'\(text)'"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: Building rules

    @Test("Weekly on several weekdays")
    func weeklyOnDays() throws {
        let built = try rule(["recurrence": "weekly", "recurrence_days": ["mon", "Wednesday", "FRI"]])
        #expect(built.frequency == .weekly)
        #expect(built.daysOfTheWeek?.map(\.dayOfTheWeek) == [.monday, .wednesday, .friday])
        #expect(built.daysOfTheWeek?.allSatisfy { $0.weekNumber == 0 } == true)
        #expect(Recurrence.describe(built) == "every week on Mon, Wed, Fri")
    }

    @Test("A repeated day is kept once")
    func duplicateDays() throws {
        let built = try rule(["recurrence": "weekly", "recurrence_days": ["mon", "monday", "Mon"]])
        #expect(days(built) == ["Mon"])
    }

    @Test("A bare string is a one-day list")
    func bareDay() throws {
        let built = try rule(["recurrence": "weekly", "recurrence_days": "thursday"])
        #expect(days(built) == ["Thu"])
    }

    @Test("Monthly on the 2nd Tuesday")
    func nthWeekday() throws {
        let built = try rule(["recurrence": "monthly", "recurrence_days": ["2nd tuesday"]])
        #expect(built.daysOfTheWeek?.first?.dayOfTheWeek == .tuesday)
        #expect(built.daysOfTheWeek?.first?.weekNumber == 2)
        #expect(built.setPositions == nil)
        #expect(Recurrence.describe(built) == "every month on 2nd Tue")
    }

    @Test("Monthly on the last Friday")
    func lastWeekday() throws {
        let built = try rule(["recurrence": "monthly", "recurrence_days": ["last fri"]])
        #expect(built.daysOfTheWeek?.first?.weekNumber == -1)
        #expect(Recurrence.describe(built) == "every month on last Fri")
    }

    @Test("The last weekday of the month: Monday to Friday at position -1")
    func lastWeekdayOfMonth() throws {
        let built = try rule([
            "recurrence": "monthly",
            "recurrence_days": ["mon", "tue", "wed", "thu", "fri"],
            "recurrence_position": -1,
        ])
        #expect(built.daysOfTheWeek?.count == 5)
        #expect(numbers(built.setPositions) == [-1])
        #expect(Recurrence.describe(built) == "every month on the last weekday")
    }

    @Test("Positions read naturally for other day groups")
    func describesPositions() {
        let weekend = monthly(days: [.init(.saturday), .init(.sunday)], positions: [1])
        #expect(Recurrence.describe(weekend) == "every month on the 1st weekend day")
        let everyDay = monthly(days: (1...7).compactMap { EKWeekday(rawValue: $0) }.map { .init($0) }, positions: [-2])
        #expect(Recurrence.describe(everyDay) == "every month on the 2nd last day")
        let oneDay = monthly(days: [.init(.tuesday)], positions: [3])
        #expect(Recurrence.describe(oneDay) == "every month on the 3rd Tue")
        let two = monthly(days: [.init(.monday), .init(.wednesday)], positions: [1, -1])
        #expect(Recurrence.describe(two) == "every month on the 1st, last of Mon, Wed")
    }

    @Test("A position that doesn't pick among weekdays keeps its own phrase")
    func describesOtherPositions() {
        let odd = monthly(monthDays: [1, 15], positions: [2])
        #expect(Recurrence.describe(odd) == "every month on the 1st, 15th (the 2nd of each month)")
    }

    @Test("Days of the month, counted from the end too")
    func monthDays() throws {
        let built = try rule(["recurrence": "monthly", "recurrence_month_days": [15, -1]])
        #expect(numbers(built.daysOfTheMonth) == [15, -1])
        #expect(built.daysOfTheWeek == nil)
        #expect(Recurrence.describe(built) == "every month on the 15th, last day")
        let one = try rule(["recurrence": "monthly", "recurrence_month_days": [-2]])
        #expect(Recurrence.describe(one) == "every month on the 2nd last day")
    }

    @Test("Days of the month accept numeric strings and a bare number")
    func monthDayCoercion() throws {
        #expect(numbers(try rule(["recurrence": "monthly", "recurrence_month_days": ["1", "15"]]).daysOfTheMonth) == [1, 15])
        #expect(numbers(try rule(["recurrence": "monthly", "recurrence_month_days": 15]).daysOfTheMonth) == [15])
        #expect(numbers(try rule(["recurrence": "monthly", "recurrence_month_days": [15, 15]]).daysOfTheMonth) == [15])
    }

    @Test("A yearly repeat on a weekday falls in the start's month")
    func yearlyTakesStartMonth() throws {
        let november = try #require(DateParsing.parse("2026-11-26T10:00:00")).date
        let built = try rule(
            ["recurrence": "yearly", "recurrence_days": ["4th thursday"]], start: november
        )
        #expect(numbers(built.monthsOfTheYear) == [11])
        #expect(Recurrence.describe(built) == "every year on 4th Thu in Nov")
    }

    @Test("Yearly with a position: the last weekday of the start's month")
    func yearlyPosition() throws {
        let may = try #require(DateParsing.parse("2026-05-29T10:00:00")).date
        let built = try rule([
            "recurrence": "yearly", "recurrence_days": ["mon", "tue", "wed", "thu", "fri"], "recurrence_position": -1,
        ], start: may)
        #expect(numbers(built.monthsOfTheYear) == [5])
        #expect(Recurrence.describe(built) == "every year on the last weekday in May")
    }

    @Test("The yearly month is the start's where the event takes place")
    func yearlyMonthInEventZone() throws {
        // 1 Dec 08:00 in Tokyo is still 30 Nov in Los Angeles.
        let start = try #require(DateParsing.parse("2026-12-01T08:00:00+09:00")).date
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let args = Arguments(["recurrence": "yearly", "recurrence_days": ["1st tuesday"]])
        #expect(numbers(try Recurrence.rule(from: args, start: start, timeZone: tokyo)?.monthsOfTheYear) == [12])
        #expect(numbers(try Recurrence.rule(from: args, start: start, timeZone: la)?.monthsOfTheYear) == [11])
    }

    @Test("Restating the days of a yearly repeat follows a moved start; several months are kept")
    func yearlyMonthFollowsStart() throws {
        let thanksgiving = EKRecurrenceRule(
            recurrenceWith: .yearly, interval: 1,
            daysOfTheWeek: [.init(.thursday, weekNumber: 4)],
            daysOfTheMonth: nil, monthsOfTheYear: [11], weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        let march = try #require(DateParsing.parse("2027-03-01T10:00:00")).date
        let moved = try rule(["recurrence_days": ["1st monday"]], existing: thanksgiving, start: march)
        #expect(numbers(moved.monthsOfTheYear) == [3])
        // Only the count changes: the month stays.
        #expect(numbers(try rule(["recurrence_count": 3], existing: thanksgiving, start: march).monthsOfTheYear) == [11])

        let twoMonths = EKRecurrenceRule(
            recurrenceWith: .yearly, interval: 1,
            daysOfTheWeek: [.init(.monday, weekNumber: 1)],
            daysOfTheMonth: nil, monthsOfTheYear: [3, 9], weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        #expect(numbers(try rule(["recurrence_days": ["2nd monday"]], existing: twoMonths, start: march).monthsOfTheYear) == [3, 9])
    }

    @Test("The new arguments end and count like the others")
    func withEnd() throws {
        let built = try rule(["recurrence": "monthly", "recurrence_days": ["2nd tue"], "recurrence_count": 6])
        #expect(Recurrence.describe(built) == "every month on 2nd Tue, 6 times")
    }

    // MARK: Invalid combinations

    @Test("A daily repeat can't take weekdays, and the error points at weekly")
    func dailyWithDays() throws {
        let refused = try #require(refusal(["recurrence": "daily", "recurrence_days": ["mon"]]))
        #expect(refused.name == "recurrence_days")
        #expect(refused.reason.contains("weekly"))
    }

    @Test("A weekly repeat can't take an ordinal day")
    func weeklyWithOrdinal() throws {
        let refused = try #require(refusal(["recurrence": "weekly", "recurrence_days": ["mon", "2nd tuesday"]]))
        #expect(refused.name == "recurrence_days")
        #expect(refused.reason.contains("2nd Tue"))
        #expect(refused.reason.contains("monthly"))
    }

    @Test("Days of the month need a monthly repeat", arguments: ["daily", "weekly", "yearly"])
    func monthDaysNeedMonthly(frequency: String) throws {
        let refused = try #require(refusal(["recurrence": .string(frequency), "recurrence_month_days": [15]]))
        #expect(refused.name == "recurrence_month_days")
    }

    @Test("Days of the month out of range are refused", arguments: [0, 32, -32, 100])
    func monthDayRange(day: Int) throws {
        let refused = try #require(refusal(["recurrence": "monthly", "recurrence_month_days": [1, .int(day)]]))
        #expect(refused.name == "recurrence_month_days")
        #expect(refused.reason.contains("\(day)"))
    }

    @Test("Days of the month must be numbers")
    func monthDayType() throws {
        let refused = try #require(refusal(["recurrence": "monthly", "recurrence_month_days": ["fifteenth"]]))
        #expect(refused.name == "recurrence_month_days")
    }

    @Test("Weekdays and days of the month together are refused")
    func daysAndMonthDays() throws {
        let refused = try #require(refusal([
            "recurrence": "monthly", "recurrence_days": ["fri"], "recurrence_month_days": [13],
        ]))
        #expect(refused.name == "recurrence_month_days")
    }

    @Test("A position needs a monthly or yearly repeat", arguments: ["daily", "weekly"])
    func positionFrequency(frequency: String) throws {
        let refused = try #require(refusal([
            "recurrence": .string(frequency), "recurrence_position": 1,
        ]))
        #expect(refused.name == "recurrence_position")
    }

    @Test("A position needs weekdays to pick among")
    func positionNeedsDays() throws {
        let refused = try #require(refusal(["recurrence": "monthly", "recurrence_position": -1]))
        #expect(refused.name == "recurrence_position")
        #expect(refused.reason.contains("recurrence_days"))
        let withMonthDays = try #require(refusal([
            "recurrence": "monthly", "recurrence_month_days": [1], "recurrence_position": 1,
        ]))
        #expect(withMonthDays.name == "recurrence_position")
    }

    @Test("A position can't combine with an ordinal day")
    func positionWithOrdinal() throws {
        let refused = try #require(refusal([
            "recurrence": "monthly", "recurrence_days": ["2nd tue"], "recurrence_position": 1,
        ]))
        #expect(refused.name == "recurrence_position")
    }

    @Test("A position out of range is refused", arguments: [0, 6, -6, 99])
    func positionRange(position: Int) throws {
        let refused = try #require(refusal([
            "recurrence": "monthly", "recurrence_days": ["mon"], "recurrence_position": .int(position),
        ]))
        #expect(refused.name == "recurrence_position")
    }

    @Test("Days that aren't strings are refused, not dropped")
    func dayTypes() throws {
        let refused = try #require(refusal(["recurrence": "weekly", "recurrence_days": [1, 2]]))
        #expect(refused.name == "recurrence_days")
        let blank = try #require(refusal(["recurrence": "weekly", "recurrence_days": ["mon", " "]]))
        #expect(blank.name == "recurrence_days")
    }

    @Test("Days on something that doesn't repeat yet ask how often")
    func daysNeedFrequency() throws {
        let refused = try #require(refusal(["recurrence_days": ["mon"]]))
        #expect(refused.name == "recurrence")
    }

    // MARK: Updates

    @Test("New weekdays replace the old and keep interval and end")
    func updateDays() throws {
        let existing = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 2,
            daysOfTheWeek: [.init(.monday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: EKRecurrenceEnd(occurrenceCount: 8)
        )
        let updated = try rule(["recurrence_days": ["tue", "thu"]], existing: existing)
        #expect(updated.frequency == .weekly)
        #expect(updated.interval == 2)
        #expect(days(updated) == ["Tue", "Thu"])
        #expect(updated.recurrenceEnd?.occurrenceCount == 8)
    }

    @Test("Changing the count keeps the days, position and days of the month")
    func updateKeepsPattern() throws {
        let lastWeekday = monthly(
            days: [.init(.monday), .init(.tuesday), .init(.wednesday), .init(.thursday), .init(.friday)],
            positions: [-1]
        )
        let updated = try rule(["recurrence_count": 4], existing: lastWeekday)
        #expect(updated.daysOfTheWeek?.count == 5)
        #expect(numbers(updated.setPositions) == [-1])
        #expect(updated.recurrenceEnd?.occurrenceCount == 4)

        let fifteenth = monthly(monthDays: [15])
        #expect(numbers(try rule(["recurrence_interval": 3], existing: fifteenth).daysOfTheMonth) == [15])
    }

    @Test("A new position keeps the weekdays")
    func updatePosition() throws {
        let weekdays = monthly(
            days: [.init(.monday), .init(.tuesday), .init(.wednesday), .init(.thursday), .init(.friday)],
            positions: [-1]
        )
        let updated = try rule(["recurrence_position": 1], existing: weekdays)
        #expect(updated.daysOfTheWeek?.count == 5)
        #expect(numbers(updated.setPositions) == [1])
        #expect(Recurrence.describe(updated) == "every month on the 1st weekday")
    }

    @Test("Null or an empty list clears each part", arguments: [Value.null, .array([]), .string("")])
    func clearing(empty: Value) throws {
        let weekly = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [.init(.monday), .init(.friday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        let plain = try rule(["recurrence_days": empty], existing: weekly)
        #expect(plain.daysOfTheWeek == nil)
        #expect(Recurrence.describe(plain) == "every week")

        let monthDays = try rule(["recurrence_month_days": empty], existing: monthly(monthDays: [15]))
        #expect(monthDays.daysOfTheMonth == nil)
    }

    @Test("Null clears the position and keeps the weekdays")
    func clearPosition() throws {
        let existing = monthly(days: [.init(.monday), .init(.friday)], positions: [2])
        let updated = try rule(["recurrence_position": .null], existing: existing)
        #expect(updated.setPositions == nil)
        #expect(days(updated) == ["Mon", "Fri"])
    }

    @Test("Clearing the weekdays drops the position that picked among them")
    func clearingDaysDropsPosition() throws {
        let existing = monthly(days: [.init(.monday), .init(.friday)], positions: [-1])
        let updated = try rule(["recurrence_days": []], existing: existing)
        #expect(updated.daysOfTheWeek == nil)
        #expect(updated.setPositions == nil)
    }

    @Test("Weekdays replace days of the month, and days of the month replace weekdays")
    func switchingPatterns() throws {
        let toWeekday = try rule(["recurrence_days": ["2nd tue"]], existing: monthly(monthDays: [15]))
        #expect(toWeekday.daysOfTheMonth == nil)
        #expect(days(toWeekday) == ["2nd Tue"])

        let existing = monthly(days: [.init(.monday), .init(.friday)], positions: [-1])
        let toMonthDay = try rule(["recurrence_month_days": [1]], existing: existing)
        #expect(toMonthDay.daysOfTheWeek == nil)
        #expect(toMonthDay.setPositions == nil)
        #expect(numbers(toMonthDay.daysOfTheMonth) == [1])
    }

    @Test("A merge that leaves a bad combination is refused")
    func mergedValidation() throws {
        // An ordinal day added to a rule that already has a position.
        let existing = monthly(days: [.init(.monday)], positions: [2])
        let refused = try #require(refusal(["recurrence_days": ["last fri"]], existing: existing))
        #expect(refused.name == "recurrence_position")
        #expect(refused.reason.contains("null"))
        // A position added to a weekly rule.
        let weekly = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [.init(.monday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil
        )
        #expect(try #require(refusal(["recurrence_position": 1], existing: weekly)).name == "recurrence_position")
    }

    @Test("A new frequency starts afresh: monthly days don't carry into weekly")
    func newFrequencyDropsPattern() throws {
        let existing = monthly(days: [.init(.tuesday, weekNumber: 2)])
        let updated = try rule(["recurrence": "weekly"], existing: existing)
        #expect(updated.daysOfTheWeek == nil)
        let withDays = try rule(["recurrence": "weekly", "recurrence_days": ["tue"]], existing: existing)
        #expect(days(withDays) == ["Tue"])
    }

    @Test("Only the new arguments make a call count as a repeat change")
    func requested() {
        #expect(Recurrence.isRequested(in: Arguments(["recurrence_days": ["mon"]])))
        #expect(Recurrence.isRequested(in: Arguments(["recurrence_position": 1])))
        #expect(Recurrence.isRequested(in: Arguments(["recurrence_month_days": [1]])))
        #expect(!Recurrence.isRequested(in: Arguments(["title": "x"])))
    }
}
