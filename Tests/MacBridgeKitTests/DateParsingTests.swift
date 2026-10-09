//
//  DateParsingTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Date parsing, formatting and relative values.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// Date handling is where a silent time-zone shift would quietly corrupt the
/// user's calendar, so the edge cases are pinned here.
@Suite("Date parsing")
struct DateParsingTests {

    @Test("A date-only string parses as local midnight, not UTC")
    func dateOnlyStaysLocal() throws {
        let parsed = try #require(DateParsing.parse("2026-09-28"))
        #expect(parsed.hasTime == false)

        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: parsed.date)
        #expect(c.year == 2026)
        #expect(c.month == 9)
        #expect(c.day == 28)
        // The regression this guards: reading "2026-09-28" as UTC midnight shows
        // up as the 27th at 20:00 for anyone west of Greenwich.
        #expect(c.hour == 0, "date-only must not be read as UTC")
    }

    @Test("Local date-times parse and report a time")
    func localDateTime() throws {
        let parsed = try #require(DateParsing.parse("2026-09-28T15:30:00"))
        #expect(parsed.hasTime)
        let c = Calendar.current.dateComponents([.hour, .minute], from: parsed.date)
        #expect(c.hour == 15)
        #expect(c.minute == 30)
    }

    @Test("ISO-8601 with an explicit offset is honoured")
    func offsetRespected() throws {
        let utc = try #require(DateParsing.parse("2026-09-28T12:00:00Z"))
        let plusTwo = try #require(DateParsing.parse("2026-09-28T14:00:00+02:00"))
        #expect(utc.date == plusTwo.date, "the same instant written two ways")
    }

    @Test("Fractional seconds are accepted")
    func fractionalSeconds() {
        #expect(DateParsing.parse("2026-09-28T12:00:00.123Z") != nil)
    }

    @Test("Relative words resolve against the supplied now")
    func relativeWords() throws {
        let now = try #require(DateParsing.parse("2026-09-28T13:00:00")).date
        let cal = Calendar.current

        let today = try #require(DateParsing.parse("today", now: now))
        #expect(today.date == cal.startOfDay(for: now))
        #expect(today.hasTime == false)

        let tomorrow = try #require(DateParsing.parse("tomorrow", now: now))
        #expect(cal.dateComponents([.day], from: today.date, to: tomorrow.date).day == 1)

        let yesterday = try #require(DateParsing.parse("yesterday", now: now))
        #expect(cal.dateComponents([.day], from: yesterday.date, to: today.date).day == 1)

        #expect(try #require(DateParsing.parse("now", now: now)).hasTime)
    }

    @Test("Relative offsets shift by the right unit and direction", arguments: [
        ("+7d", Calendar.Component.day, 7),
        ("-3d", .day, -3),
        ("+2w", .day, 14),
        ("+1m", .month, 1),
        ("+1y", .year, 1),
    ])
    func relativeOffsets(token: String, unit: Calendar.Component, expected: Int) throws {
        let now = try #require(DateParsing.parse("2026-09-28T13:00:00")).date
        let cal = Calendar.current
        let parsed = try #require(DateParsing.parse(token, now: now))
        let delta = cal.dateComponents([unit], from: cal.startOfDay(for: now), to: parsed.date)
        #expect(delta.value(for: unit) == expected)
    }

    @Test("Unparseable input is rejected rather than guessed at", arguments: [
        "", "   ", "next tuesday", "28/09/2026", "tomorrow afternoon", "+d", "+3q", "2026-13-45",
    ])
    func rejectsGarbage(bad: String) {
        #expect(DateParsing.parse(bad) == nil, "should not have parsed '\(bad)'")
    }

    @Test("Formatting round-trips through the parser")
    func roundTrip() throws {
        let original = try #require(DateParsing.parse("2026-09-28T15:30:00")).date
        let reparsed = try #require(DateParsing.parse(DateParsing.format(original, allDay: false)))
        #expect(
            Int(reparsed.date.timeIntervalSince1970) == Int(original.timeIntervalSince1970),
            "a formatted timestamp must parse back to the same instant"
        )
    }

    @Test("All-day values format as a bare date")
    func allDayFormatting() throws {
        let date = try #require(DateParsing.parse("2026-09-28")).date
        #expect(DateParsing.format(date, allDay: true) == "2026-09-28")
        #expect(DateParsing.format(date, allDay: false).contains("T"))
    }

    @Test("endOfDay lands on the same day, last second")
    func endOfDay() throws {
        let date = try #require(DateParsing.parse("2026-09-28")).date
        let c = Calendar.current.dateComponents([.day, .hour, .minute, .second], from: DateParsing.endOfDay(date))
        #expect(c.day == 28)
        #expect(c.hour == 23)
        #expect(c.minute == 59)
        #expect(c.second == 59)
    }
}
