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
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    /// `2026-09-26T15:00:00` — local wall time with no offset.
    public static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    /// `2026-09-26T15:00:00-05:00` — the canonical output form for timed values.
    public static let offsetDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    // MARK: Parsing

    /// Parse a date argument.
    ///
    /// Accepted, in order of attempt:
    /// - relative words: `now`, `today`, `tomorrow`, `yesterday`
    /// - relative offsets: `+7d`, `-3d`, `+2w`, `+1mo`, `+1y` (date-only), and
    ///   `+2h`, `+30min` (timed)
    /// - `yyyy-MM-dd`
    /// - `yyyy-MM-dd'T'HH:mm[:ss[.fff]]`, with `T` or a space, read as local time
    ///   unless followed by `Z` or an offset such as `+02:00`
    ///
    /// `+1m` is refused rather than guessed: a model writes it for minutes about as
    /// often as for months.
    ///
    /// - Returns: the parsed instant, and whether the input carried a time.
    public static func parse(_ raw: String, now: Date = Date()) -> (date: Date, hasTime: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let relative = parseRelative(s, now: now) { return relative }
        return parseAbsolute(s)
    }

    /// `2026-09-28`, or a date-time in any of the shapes models emit: with or
    /// without seconds, fractional seconds, a `T` or a space, and an optional zone.
    private static let absolutePattern = try! NSRegularExpression(pattern: #"""
        ^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?)?$
        """#, options: [.caseInsensitive])

    private static func parseAbsolute(_ s: String) -> (date: Date, hasTime: Bool)? {
        let range = NSRange(s.startIndex..., in: s)
        guard let match = absolutePattern.firstMatch(in: s, range: range) else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        func number(_ i: Int) -> Int? { group(i).flatMap { Int($0) } }

        guard let year = number(1), let month = number(2), let day = number(3) else { return nil }
        let hasTime = group(4) != nil
        let hour = number(4) ?? 0
        let minute = number(5) ?? 0
        let second = number(6) ?? 0

        var calendar = Calendar(identifier: .gregorian)
        if let zone = group(7) {
            guard let tz = timeZone(fromDesignator: zone) else { return nil }
            calendar.timeZone = tz
        } else {
            // A bare date-time is local wall time. A date-only value must be too:
            // read as UTC midnight it lands on the previous day west of Greenwich.
            calendar.timeZone = .autoupdatingCurrent
        }

        // Range-check by hand: Calendar would silently roll 2026-13-45 forward.
        guard (1...12).contains(month), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second)
        else { return nil }
        let monthStart = DateComponents(year: year, month: month, day: 1)
        guard let firstOfMonth = calendar.date(from: monthStart),
              let days = calendar.range(of: .day, in: .month, for: firstOfMonth),
              days.contains(day)
        else { return nil }

        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let date = calendar.date(from: components) else { return nil }
        return (date, hasTime)
    }

    /// `Z`, `+02`, `+0200` or `+02:00`.
    private static func timeZone(fromDesignator designator: String) -> TimeZone? {
        if designator.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = designator.hasPrefix("-") ? -1 : 1
        let digits = designator.dropFirst().filter(\.isNumber)
        guard digits.count == 2 || digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.dropFirst(2).isEmpty ? "0" : String(digits.dropFirst(2))),
              hours <= 18, minutes < 60
        else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
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

        // +7d / -3d / +2w / +1mo / +1y, and the timed +2h / +30min
        let pattern = #"^([+-])(\d{1,6})(d|w|mo|y|h|min)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let signRange = Range(match.range(at: 1), in: s),
              let amountRange = Range(match.range(at: 2), in: s),
              let unitRange = Range(match.range(at: 3), in: s),
              let amount = Int(s[amountRange])
        else { return nil }
        let value = (s[signRange] == "-" ? -1 : 1) * amount

        switch s[unitRange].lowercased() {
        case "h":
            return cal.date(byAdding: .hour, value: value, to: now).map { ($0, true) }
        case "min":
            return cal.date(byAdding: .minute, value: value, to: now).map { ($0, true) }
        case let unit:
            let component: Calendar.Component
            switch unit {
            case "d": component = .day
            case "w": component = .weekOfYear
            case "mo": component = .month
            default: component = .year
            }
            guard let d = cal.date(byAdding: component, value: value, to: now) else { return nil }
            return (cal.startOfDay(for: d), false)
        }
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
