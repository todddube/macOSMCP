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
        ("+1mo", .month, 1),
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
        "2026-02-30", "2026-09-28T24:00", "2026-09-28T12:60:00", "2026-09-28T", "2026-09-28T12",
        // Minutes or months? Refused rather than guessed.
        "+1m",
    ])
    func rejectsGarbage(bad: String) {
        #expect(DateParsing.parse(bad) == nil, "should not have parsed '\(bad)'")
    }

    @Test("The date-time shapes models emit all read as the same local time", arguments: [
        "2026-09-28T15:30", "2026-09-28 15:30", "2026-09-28T15:30:00", "2026-09-28 15:30:00",
        "2026-09-28T15:30:00.000", "2026-09-28t15:30",
    ])
    func lenientLocalShapes(input: String) throws {
        let parsed = try #require(DateParsing.parse(input), "should have parsed '\(input)'")
        #expect(parsed.hasTime)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed.date)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 9, 28, 15, 30, 0])
    }

    @Test("A single-digit hour is read, as models often write one")
    func singleDigitHour() throws {
        let parsed = try #require(DateParsing.parse("2026-09-28 9:05"))
        #expect(Calendar.current.dateComponents([.hour, .minute], from: parsed.date) == DateComponents(hour: 9, minute: 5))
    }

    @Test("Offsets are honoured with or without seconds and colons")
    func offsetShapes() throws {
        let expected = try #require(DateParsing.parse("2026-09-28T12:00:00Z")).date
        for input in ["2026-09-28T14:00+02:00", "2026-09-28T14:00:00+0200", "2026-09-28T14:00+02",
                      "2026-09-28T12:00Z", "2026-09-28 07:00:00-05:00"] {
            #expect(DateParsing.parse(input)?.date == expected, "'\(input)'")
        }
    }

    @Test("Hour and minute offsets keep the time of day")
    func timedOffsets() throws {
        let now = try #require(DateParsing.parse("2026-09-28T13:10:00")).date
        let inTwoHours = try #require(DateParsing.parse("+2h", now: now))
        #expect(inTwoHours.hasTime)
        #expect(inTwoHours.date.timeIntervalSince(now) == 2 * 3600)

        let halfHourAgo = try #require(DateParsing.parse("-30min", now: now))
        #expect(halfHourAgo.date.timeIntervalSince(now) == -30 * 60)
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

    // MARK: Time zones

    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test("A floating time is wall-clock time in the zone given")
    func floatingInZone() throws {
        let nine = try #require(DateParsing.parse("2026-07-01T09:00", timeZone: newYork))
        #expect(nine.hasTime)
        #expect(nine.date == DateParsing.parse("2026-07-01T13:00:00Z")?.date, "09:00 EDT is 13:00 UTC")
        // Standard time in winter, so the zone is a real zone, not a fixed offset.
        let winter = try #require(DateParsing.parse("2026-01-15 09:00:00", timeZone: newYork))
        #expect(winter.date == DateParsing.parse("2026-01-15T14:00:00Z")?.date)
    }

    @Test("An explicit offset or Z is honoured whatever the zone")
    func explicitOffsetWins() throws {
        let utc = try #require(DateParsing.parse("2026-07-01T09:00:00Z", timeZone: tokyo))
        #expect(utc.date == DateParsing.parse("2026-07-01T09:00:00Z")?.date)
        let offset = try #require(DateParsing.parse("2026-07-01T09:00:00-07:00", timeZone: tokyo))
        #expect(offset.date == DateParsing.parse("2026-07-01T16:00:00Z")?.date)
    }

    @Test("Date-only and relative values ignore the zone")
    func zoneLeavesOthersAlone() throws {
        #expect(DateParsing.parse("2026-07-01", timeZone: tokyo)?.date == DateParsing.parse("2026-07-01")?.date)
        let now = try #require(DateParsing.parse("2026-09-28T13:00:00")).date
        #expect(DateParsing.parse("+2h", now: now, timeZone: tokyo)?.date == now.addingTimeInterval(7200))
        #expect(DateParsing.parse("tomorrow", now: now, timeZone: tokyo)?.date
            == DateParsing.parse("tomorrow", now: now)?.date)
        #expect(DateParsing.parse("now", now: now, timeZone: tokyo)?.date == now)
    }

    @Test("No zone keeps the Mac's, as before")
    func nilZoneIsLocal() {
        #expect(DateParsing.parse("2026-09-28T15:30:00", timeZone: nil)?.date
            == DateParsing.parse("2026-09-28T15:30:00")?.date)
    }

    @Test("Re-anchoring keeps the wall-clock time in the new zone")
    func reanchor() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let nineLA = try #require(DateParsing.parse("2026-07-01T09:00:00-07:00")).date
        let moved = DateParsing.reanchor(nineLA, from: la, to: newYork)
        #expect(moved == DateParsing.parse("2026-07-01T09:00:00-04:00")?.date)
        #expect(DateParsing.reanchor(nineLA, from: la, to: la) == nineLA)
        // Across the date line the day is kept too.
        let lateLA = try #require(DateParsing.parse("2026-07-01T23:30:00-07:00")).date
        #expect(DateParsing.reanchor(lateLA, from: la, to: tokyo) == DateParsing.parse("2026-07-01T23:30:00+09:00")?.date)
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
