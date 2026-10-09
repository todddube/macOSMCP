//
//  FreeBusyTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Free/busy gap arithmetic.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// `FreeBusy` is deliberately EventKit-free so the gap arithmetic behind
/// `calendar_find_available_times` can be tested exactly — that tool is the one
/// place where an off-by-one would silently offer the user a busy slot.
@Suite("FreeBusy gap finding")
struct FreeBusyTests {

    /// 2026-09-28 is a Monday. All times local.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 9
        c.day = 28
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func span(_ startHour: Int, _ endHour: Int) -> DateInterval {
        DateInterval(start: at(startHour), end: at(endHour))
    }

    @Test("An empty day yields the whole window")
    func emptyDay() {
        let slots = FreeBusy.freeSlots(in: span(9, 17), busy: [], minimumDuration: 1800)
        #expect(slots.count == 1)
        #expect(slots.first?.start == at(9))
        #expect(slots.first?.end == at(17))
    }

    @Test("A midday meeting splits the window in two")
    func singleMeeting() {
        let slots = FreeBusy.freeSlots(in: span(9, 17), busy: [span(12, 13)], minimumDuration: 1800)
        #expect(slots.count == 2)
        #expect(slots.first?.end == at(12))
        #expect(slots.last?.start == at(13))
    }

    @Test("Gaps shorter than the requested duration are dropped")
    func tooShort() {
        // Leaves 09:00–09:20 and 09:50–17:00; only the second fits 30 minutes.
        let busy = [DateInterval(start: at(9, 20), end: at(9, 50))]
        let slots = FreeBusy.freeSlots(in: span(9, 17), busy: busy, minimumDuration: 1800)
        #expect(slots.count == 1)
        #expect(slots.first?.start == at(9, 50))
    }

    @Test("Overlapping and nested meetings merge rather than double-count")
    func overlapping() {
        let slots = FreeBusy.freeSlots(
            in: span(9, 17),
            busy: [span(10, 12), span(11, 13), span(11, 12)],
            minimumDuration: 3600
        )
        #expect(slots.count == 2)
        #expect(slots.first?.end == at(10))
        #expect(slots.last?.start == at(13))
    }

    @Test("Back-to-back meetings leave no zero-length phantom gap")
    func backToBack() {
        let slots = FreeBusy.freeSlots(in: span(9, 17), busy: [span(10, 11), span(11, 12)], minimumDuration: 900)
        #expect(slots.count == 2)
        #expect(slots.allSatisfy { $0.duration >= 900 })
    }

    @Test("Meetings outside the window do not consume it")
    func outsideWindow() {
        let slots = FreeBusy.freeSlots(in: span(9, 17), busy: [span(7, 8), span(18, 19)], minimumDuration: 3600)
        #expect(slots.count == 1)
        #expect(slots.first?.start == at(9))
        #expect(slots.first?.end == at(17))
    }

    @Test("A meeting covering the whole window leaves nothing")
    func fullyBooked() {
        #expect(FreeBusy.freeSlots(in: span(9, 17), busy: [span(8, 18)], minimumDuration: 900).isEmpty)
    }

    @Test("A window shorter than the requested duration yields nothing")
    func windowTooSmall() {
        #expect(FreeBusy.freeSlots(in: span(9, 10), busy: [], minimumDuration: 7200).isEmpty)
    }

    @Test("A non-positive duration yields nothing rather than every instant")
    func nonPositiveDuration() {
        #expect(FreeBusy.freeSlots(in: span(9, 17), busy: [], minimumDuration: 0).isEmpty)
    }

    @Test("Merging normalises order and overlap")
    func merging() {
        let merged = FreeBusy.merge([span(14, 15), span(9, 10), span(9, 11)])
        #expect(merged.count == 2)
        #expect(merged.first?.start == at(9))
        #expect(merged.first?.end == at(11))
    }

    @Test("An end hour of 24 means midnight, not an empty day")
    func endHourTwentyFour() {
        // date(bySettingHour: 24) returns nil, which silently skipped every day and
        // made day_end_hour: 24 indistinguishable from a fully booked calendar.
        let range = DateInterval(start: at(0), end: at(23, 59))
        let windows = FreeBusy.dailyWindows(in: range, startHour: 9, endHour: 24)

        #expect(!windows.isEmpty, "hour 24 must produce a window")
        #expect(windows.first?.end ?? at(0) > at(23), "the window should run to end of day")
    }

    @Test("Daily windows cover each day and reject inverted hours")
    func dailyWindows() {
        let range = DateInterval(start: at(0), end: at(0).addingTimeInterval(3 * 86_400))
        let windows = FreeBusy.dailyWindows(in: range, startHour: 9, endHour: 17)
        #expect(windows.count >= 3)
        #expect(windows.allSatisfy { $0.duration == 8 * 3600 })
        #expect(FreeBusy.dailyWindows(in: range, startHour: 17, endHour: 9).isEmpty)
    }
}
