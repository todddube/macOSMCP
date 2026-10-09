//
//  FreeBusy.swift
//  MacBridgeKit · MacBridge
//
//  Gap finding for calendar_find_available_times. EventKit-free, so directly testable.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Gap-finding for `calendar_find_available_times`.
///
/// Deliberately free of EventKit so it can be unit-tested directly: it takes
/// windows and busy intervals and returns the gaps.
public enum FreeBusy {

    /// Subtract `busy` from `window` and return the remaining gaps that are at
    /// least `minimumDuration` long.
    ///
    /// Busy intervals may overlap, nest, repeat, or fall entirely outside the
    /// window; all of those are handled by merging before subtracting.
    public static func freeSlots(
        in window: DateInterval,
        busy: [DateInterval],
        minimumDuration: TimeInterval
    ) -> [DateInterval] {
        guard minimumDuration > 0, window.duration >= minimumDuration else { return [] }

        let merged = merge(busy.compactMap { $0.intersection(with: window) })

        var slots: [DateInterval] = []
        var cursor = window.start

        for block in merged {
            if block.start > cursor {
                let gap = DateInterval(start: cursor, end: block.start)
                if gap.duration >= minimumDuration { slots.append(gap) }
            }
            cursor = max(cursor, block.end)
        }

        if cursor < window.end {
            let gap = DateInterval(start: cursor, end: window.end)
            if gap.duration >= minimumDuration { slots.append(gap) }
        }

        return slots
    }

    /// Collapse overlapping and touching intervals into a sorted, disjoint set.
    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }

        var result: [DateInterval] = [sorted[0]]
        for interval in sorted.dropFirst() {
            let last = result[result.count - 1]
            if interval.start <= last.end {
                if interval.end > last.end {
                    result[result.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// The working-hours window for each day in `range`.
    ///
    /// Days where the window would be empty or inverted are skipped, so callers
    /// cannot accidentally ask for gaps between 5pm and 9am.
    public static func dailyWindows(
        in range: DateInterval,
        startHour: Int,
        endHour: Int,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        guard startHour < endHour else { return [] }

        var windows: [DateInterval] = []
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)

        while day <= lastDay {
            if let open = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
               let close = endOfWorkingDay(hour: endHour, on: day, calendar: calendar),
               open < close {
                let window = DateInterval(start: open, end: close)
                if let clipped = window.intersection(with: range), clipped.duration > 0 {
                    windows.append(clipped)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return windows
    }

    /// The closing instant for `hour` on `day`.
    ///
    /// `date(bySettingHour:)` returns nil for hour 24, which silently skipped every
    /// day and made `day_end_hour: 24` return no slots at all — indistinguishable
    /// from a fully booked calendar. 24 means midnight at the end of the day.
    private static func endOfWorkingDay(hour: Int, on day: Date, calendar: Calendar) -> Date? {
        guard hour >= 24 else {
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        else { return nil }
        return calendar.startOfDay(for: nextDay)
    }
}
