//
//  DateParsing.swift
//  MacBridgeKit · MacBridge
//
//  Date parsing and formatting shared by every tool.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Date parsing and formatting shared by every tool.
///
/// Widened from an implementation that accepted only `yyyy-MM-dd` and
/// `yyyy-MM-dd'T'HH:mm:ss`. Models reliably emit offsets and relative words too,
/// so both are accepted here; output is always a single canonical form so clients
/// never have to guess.
public struct DateParsing {

    // MARK: Formatters

    /// `2026-09-26` — used for all-day events and date-only reminder dues.
    public static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// `2026-09-26T15:00:00` — local wall time with no offset.
    public static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    /// `2026-09-26T15:00:00-05:00` — the canonical output form for timed values.
    public static let offsetDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.timeZone = .current
        return f
    }()

    // MARK: Parsing

    /// Parse a date argument.
    ///
    /// Accepted, in order of attempt:
    /// - relative words: `now`, `today`, `tomorrow`, `yesterday`
    /// - relative offsets: `+7d`, `-3d`, `+2w`, `+1m`
    /// - `yyyy-MM-dd`
    /// - `yyyy-MM-dd'T'HH:mm:ss` (local)
    /// - full ISO-8601 with offset or `Z`
    ///
    /// - Returns: the parsed instant, and whether the input carried a time.
    public static func parse(_ raw: String, now: Date = Date()) -> (date: Date, hasTime: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let relative = parseRelative(s, now: now) { return relative }

        // Date-only must be tried before the offset parser, which would happily
        // read "2026-09-26" as midnight UTC and shift the day for most users.
        if s.count == 10, let d = dateOnly.date(from: s) { return (d, false) }

        if let d = localDateTime.date(from: s) { return (d, true) }
        if let d = offsetDateTime.date(from: s) { return (d, true) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return (d, true) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return (d, true) }

        return nil
    }

    private static func parseRelative(_ s: String, now: Date) -> (date: Date, hasTime: Bool)? {
        let cal = Calendar.current
        switch s.lowercased() {
        case "now":
            return (now, true)
        case "today":
            return (cal.startOfDay(for: now), false)
        case "tomorrow":
            return (cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now), false)
        case "yesterday":
            return (cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now) ?? now), false)
        default:
            break
        }

        // +7d / -3d / +2w / +1m / +1y
        guard let match = s.range(of: #"^([+-])(\d+)([dwmy])$"#, options: .regularExpression) else {
            return nil
        }
        let token = String(s[match])
        let sign = token.hasPrefix("-") ? -1 : 1
        let unitChar = token.last!
        let digits = token.dropFirst().dropLast()
        guard let amount = Int(digits) else { return nil }

        let component: Calendar.Component
        switch unitChar {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        default: component = .year
        }
        guard let d = cal.date(byAdding: component, value: sign * amount, to: now) else { return nil }
        return (cal.startOfDay(for: d), false)
    }

    // MARK: Formatting

    /// Format for output: date-only when `allDay`, otherwise offset date-time.
    public static func format(_ date: Date, allDay: Bool) -> String {
        allDay ? dateOnly.string(from: date) : offsetDateTime.string(from: date)
    }

    /// End of the calendar day containing `date`, used to make an inclusive range.
    public static func endOfDay(_ date: Date) -> Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }
}
