//
//  Recurrence.swift
//  MacBridgeKit · MacBridge
//
//  Builds an EKRecurrenceRule from the flat arguments a model can express.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation

/// Builds an `EKRecurrenceRule` from the flat arguments a model can express.
///
/// Full RFC-5545 rules are out of scope; this covers the repeats people actually
/// ask for: "every week", "every 2 weeks, 10 times", "every Mon, Wed and Fri",
/// "the 2nd Tuesday of each month", "the last weekday of the month", "on the 15th
/// and the last day".
enum Recurrence {

    static let allowedFrequencies = ["daily", "weekly", "monthly", "yearly"]

    /// Every argument that describes a repeat.
    static let argumentNames: Set<String> = [
        "recurrence", "recurrence_interval", "recurrence_count", "recurrence_until",
        "recurrence_days", "recurrence_position", "recurrence_month_days",
    ]

    /// The positions `recurrence_position` accepts: the 1st to 5th, or counted
    /// from the end.
    static let positionRange = -5...5

    /// The most `recurrence_days` items accepted, counted before repeats are
    /// dropped. Real patterns use a handful; this only bounds a runaway list.
    static let maxDays = 35

    /// What an update asks to do with an item's repeat.
    enum Change {
        /// Stop repeating.
        case remove
        /// Repeat by this rule, replacing any existing one.
        case set(EKRecurrenceRule)
    }

    /// True when the call mentions the repeat at all.
    static func isRequested(in args: Arguments) -> Bool {
        !argumentNames.isDisjoint(with: args.keys)
    }

    /// The repeat a new item asks for.
    ///
    /// - Parameter start: the item's start or due date; see ``change(from:existing:splitsSeries:start:timeZone:)``.
    /// - Parameter timeZone: the zone `start` is in, for its month; nil for the Mac's.
    /// - Returns: nil when the caller asked for no recurrence.
    static func rule(from args: Arguments, start: Date? = nil, timeZone: TimeZone? = nil) throws -> EKRecurrenceRule? {
        guard case .set(let rule) = try change(from: args, existing: nil, start: start, timeZone: timeZone) else {
            return nil
        }
        return rule
    }

    /// The repeat an update asks for, or nil when it doesn't mention one.
    ///
    /// Parts not given are kept from `existing`, so "make it every 2 weeks" keeps
    /// the weekly frequency and "stop after 10 times" keeps both. A new frequency
    /// starts afresh, because an end chosen for a daily repeat means something else
    /// for a monthly one.
    ///
    /// The day pattern merges like the rest: `recurrence_days`,
    /// `recurrence_position` and `recurrence_month_days` each replace only their
    /// own part, and null or `[]` clears it. Weekdays and days of the month are two
    /// ways to say which day, so giving one clears the other, and clearing the
    /// weekdays drops the position, which only picks among them.
    ///
    /// - Parameter splitsSeries: true when the change starts a new series at a
    ///   later occurrence (span `future_events`). An end kept as a count would then
    ///   count afresh from there, so a series of 10 changed at the 6th would run to
    ///   15; the caller is asked to restate the end instead.
    /// - Parameter start: the item's start (or a reminder's due date). A yearly
    ///   repeat given `recurrence_days` falls in this date's month, since "the 4th
    ///   Thursday" of a whole year would be in January.
    /// - Parameter timeZone: the zone the item takes place in, which decides
    ///   `start`'s month; nil for the Mac's.
    static func change(
        from args: Arguments,
        existing: EKRecurrenceRule?,
        splitsSeries: Bool = false,
        start: Date? = nil,
        timeZone: TimeZone? = nil
    ) throws -> Change? {
        guard isRequested(in: args) else { return nil }

        let frequency: EKRecurrenceFrequency
        var base = existing
        if let raw = args.optionalString("recurrence") {
            switch raw.lowercased() {
            case "daily": frequency = .daily
            case "weekly": frequency = .weekly
            case "monthly": frequency = .monthly
            case "yearly": frequency = .yearly
            case "none": return .remove
            default:
                throw MacBridgeError.invalidArgument(
                    name: "recurrence",
                    reason: "expected one of \(allowedFrequencies.joined(separator: ", ")) or none"
                )
            }
            if frequency != existing?.frequency { base = nil }
        } else if isBlank("recurrence", in: args) {
            // Null or blank: the same as "none".
            return .remove
        } else if args.contains("recurrence") {
            throw MacBridgeError.invalidArgument(
                name: "recurrence",
                reason: "expected one of \(allowedFrequencies.joined(separator: ", ")) or none"
            )
        } else if let existing {
            frequency = existing.frequency
        } else {
            throw MacBridgeError.invalidArgument(
                name: "recurrence",
                reason: "this doesn't repeat yet, so say how often: daily, weekly, monthly or yearly"
            )
        }

        let interval = isBlank("recurrence_interval", in: args)
            ? 1
            : try args.optionalInt("recurrence_interval", in: 1...999) ?? base?.interval ?? 1

        // count and until are mutually exclusive in EventKit; count wins if both
        // are supplied, since it is the less ambiguous of the two. Either given
        // as null or blank means repeat forever.
        var end = base?.recurrenceEnd
        if isBlank("recurrence_count", in: args) || isBlank("recurrence_until", in: args) {
            end = nil
        }
        if !isBlank("recurrence_count", in: args),
           let count = try args.optionalInt("recurrence_count", in: 1...9999) {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if args.contains("recurrence_until"), !isBlank("recurrence_until", in: args),
                  args.optionalString("recurrence_until") == nil {
            throw MacBridgeError.invalidArgument(name: "recurrence_until", reason: "expected a date string")
        } else if let until = try args.optionalDate("recurrence_until") {
            // A date-only end means through that day. Midnight at its start would
            // drop an occurrence later that same day.
            end = EKRecurrenceEnd(end: until.hasTime ? until.date : DateParsing.endOfDay(until.date))
        }

        let endRestated = ["recurrence_count", "recurrence_until"].contains(where: args.contains)
        if splitsSeries, !endRestated, let kept = end, kept.occurrenceCount > 0 {
            throw MacBridgeError.invalidArgument(
                name: "recurrence_count",
                reason: """
                    this series ends after \(kept.occurrenceCount) occurrences, counted from its first. \
                    Changing it from a later occurrence would count again from there, so say how it \
                    should end: recurrence_count for the occurrences from this one on, \
                    recurrence_until for a date, or null to repeat forever.
                    """
            )
        }

        // The rest of a kept rule comes along too: built from frequency, interval
        // and end alone, "weekly on Mon, Wed and Fri" became plain weekly and the
        // Wednesday and Friday occurrences were deleted.
        var pattern = Pattern(
            days: base?.daysOfTheWeek ?? [],
            monthDays: base?.daysOfTheMonth?.map(\.intValue) ?? [],
            positions: base?.setPositions?.map(\.intValue) ?? [],
            months: base?.monthsOfTheYear?.map(\.intValue) ?? []
        )
        let requested = try PatternRequest(args)
        if !requested.isEmpty {
            pattern = try pattern.applying(requested, frequency: frequency, start: start, timeZone: timeZone)
        }

        guard base != nil || !pattern.isEmpty else {
            return .set(EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end))
        }
        func numbers(_ values: [Int]) -> [NSNumber]? { values.isEmpty ? nil : values.map { NSNumber(value: $0) } }
        return .set(EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: pattern.days.isEmpty ? nil : pattern.days,
            daysOfTheMonth: numbers(pattern.monthDays),
            monthsOfTheYear: numbers(pattern.months),
            weeksOfTheYear: base?.weeksOfTheYear,
            daysOfTheYear: base?.daysOfTheYear,
            setPositions: numbers(pattern.positions),
            end: end
        ))
    }

    // MARK: Day patterns

    /// The day pattern arguments of one call. Each is nil when not given, and an
    /// empty list (or a nil position) when given as null or `[]`, to clear it.
    struct PatternRequest {
        var days: [EKRecurrenceDayOfWeek]?
        var monthDays: [Int]?
        var position: Int??

        var isEmpty: Bool { days == nil && monthDays == nil && position == nil }

        init(days: [EKRecurrenceDayOfWeek]? = nil, monthDays: [Int]? = nil, position: Int?? = nil) {
            self.days = days
            self.monthDays = monthDays
            self.position = position
        }

        /// Parses and range-checks `recurrence_days`, `recurrence_month_days` and
        /// `recurrence_position`; how they fit the frequency is checked later.
        init(_ args: Arguments) throws {
            if let names = try args.clearableStringList("recurrence_days") {
                guard names.count <= Recurrence.maxDays else {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_days", reason: "at most \(Recurrence.maxDays) days"
                    )
                }
                days = Recurrence.unique(try names.map(Recurrence.weekday(from:)))
            }
            if let values = try args.clearableIntList("recurrence_month_days") {
                for value in values where value == 0 || !(-31...31).contains(value) {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_month_days",
                        reason: "\(value) is not a day of the month; use 1 to 31, or -1 for the last day, "
                            + "-2 for the day before it, down to -31"
                    )
                }
                var seen = Set<Int>()
                monthDays = values.filter { seen.insert($0).inserted }
            }
            if args.contains("recurrence_position") {
                if args.clearableString("recurrence_position") == "" {
                    position = .some(nil)
                } else {
                    let value = try args.optionalInt("recurrence_position")
                    guard let value, value != 0, Recurrence.positionRange.contains(value) else {
                        throw MacBridgeError.invalidArgument(
                            name: "recurrence_position",
                            reason: "expected 1 to 5, or -1 (last) to -5 counted from the end; null removes it"
                        )
                    }
                    position = .some(value)
                }
            }
        }
    }

    /// Which days within each period a rule falls on.
    struct Pattern: Equatable {
        var days: [EKRecurrenceDayOfWeek] = []
        var monthDays: [Int] = []
        var positions: [Int] = []
        var months: [Int] = []

        var isEmpty: Bool { days.isEmpty && monthDays.isEmpty && positions.isEmpty && months.isEmpty }

        /// This pattern with `request` merged in, validated against `frequency`.
        func applying(
            _ request: PatternRequest,
            frequency: EKRecurrenceFrequency,
            start: Date?,
            timeZone: TimeZone?
        ) throws -> Pattern {
            if let days = request.days, !days.isEmpty, let monthDays = request.monthDays, !monthDays.isEmpty {
                throw MacBridgeError.invalidArgument(
                    name: "recurrence_month_days",
                    reason: """
                        give recurrence_days or recurrence_month_days, not both: a day would have to \
                        match both, so "the 15th" and "Friday" would mean only a Friday the 15th
                        """
                )
            }

            var out = self
            if let days = request.days {
                out.days = days
                if !days.isEmpty { out.monthDays = [] }
                // A position picks among the weekdays, so it goes with them.
                if days.isEmpty { out.positions = [] }
            }
            if let monthDays = request.monthDays {
                out.monthDays = monthDays
                if !monthDays.isEmpty {
                    out.days = []
                    out.positions = []
                }
            }
            if let position = request.position {
                out.positions = position.map { [$0] } ?? []
            }
            // "The 4th Thursday" of a whole year is in January; Calendar's yearly
            // repeats on a weekday name a month, and this one is the start's.
            // The month is the start's where the item takes place, which for an
            // event in another zone can differ from the Mac's. A single kept month
            // follows the start too, so an update that moves the start and restates
            // the days doesn't leave the repeat in the old month; a rule over
            // several months (made in Calendar) is left alone.
            if frequency == .yearly, let days = request.days, !days.isEmpty, out.months.count <= 1, let start {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone ?? .current
                out.months = [calendar.component(.month, from: start)]
            }

            try out.validate(for: frequency)
            return out
        }

        /// Refuses a pattern the frequency can't carry, saying what would work.
        func validate(for frequency: EKRecurrenceFrequency) throws {
            if !days.isEmpty {
                if frequency == .daily {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_days",
                        reason: """
                            a daily repeat can't be limited to some days; use recurrence 'weekly' with \
                            recurrence_days, e.g. ["mon", "tue", "wed", "thu", "fri"] for every weekday
                            """
                    )
                }
                if frequency == .weekly, let ranked = days.first(where: { $0.weekNumber != 0 }) {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_days",
                        reason: """
                            '\(Recurrence.describe(ranked))' has an ordinal, which needs recurrence 'monthly' \
                            or 'yearly'; a weekly repeat takes plain days such as "tuesday"
                            """
                    )
                }
            }
            if !monthDays.isEmpty, frequency != .monthly {
                throw MacBridgeError.invalidArgument(
                    name: "recurrence_month_days",
                    reason: "days of the month need recurrence 'monthly'"
                )
            }
            if !positions.isEmpty {
                guard frequency == .monthly || frequency == .yearly else {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_position",
                        reason: "needs recurrence 'monthly' or 'yearly'; null removes it"
                    )
                }
                guard !days.isEmpty else {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_position",
                        reason: """
                            picks among recurrence_days, so give those too: days mon to fri with \
                            position -1 is the last weekday of the month
                            """
                    )
                }
                if let ranked = days.first(where: { $0.weekNumber != 0 }) {
                    throw MacBridgeError.invalidArgument(
                        name: "recurrence_position",
                        reason: """
                            can't combine with an ordinal day such as '\(Recurrence.describe(ranked))'; \
                            use plain days with a position, or ordinal days with recurrence_position null
                            """
                    )
                }
            }
        }
    }

    /// Weekday names, full and three-letter.
    private static let weekdays: [String: EKWeekday] = [
        "sunday": .sunday, "sun": .sunday,
        "monday": .monday, "mon": .monday,
        "tuesday": .tuesday, "tue": .tuesday,
        "wednesday": .wednesday, "wed": .wednesday,
        "thursday": .thursday, "thu": .thursday,
        "friday": .friday, "fri": .friday,
        "saturday": .saturday, "sat": .saturday,
    ]

    /// Ordinal prefixes: which occurrence of the weekday in the month or year.
    private static let ordinals: [String: Int] = [
        "1": 1, "1st": 1, "first": 1,
        "2": 2, "2nd": 2, "second": 2,
        "3": 3, "3rd": 3, "third": 3,
        "4": 4, "4th": 4, "fourth": 4,
        "5": 5, "5th": 5, "fifth": 5,
        "-1": -1, "last": -1,
        "-2": -2, "second-to-last": -2, "second to last": -2, "2nd-to-last": -2, "2nd to last": -2,
        "second last": -2, "2nd last": -2,
    ]

    /// A `recurrence_days` item: "monday" or "Mon", optionally after an ordinal
    /// as in "2nd tuesday", "last fri" or "-1 fri".
    static func weekday(from text: String) throws -> EKRecurrenceDayOfWeek {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.last, let day = weekdays[name] else {
            throw MacBridgeError.invalidArgument(
                name: "recurrence_days",
                reason: """
                    '\(text)' is not a weekday; use monday to sunday or mon to sun, with an ordinal \
                    for a monthly or yearly repeat, as in "2nd tuesday" or "last friday"
                    """
            )
        }
        let prefix = words.dropLast().joined(separator: " ")
        guard !prefix.isEmpty else { return EKRecurrenceDayOfWeek(day) }
        guard let number = ordinals[prefix] else {
            throw MacBridgeError.invalidArgument(
                name: "recurrence_days",
                reason: """
                    '\(text)' has an ordinal that isn't 1st to 5th, last or second-to-last \
                    (or 1 to 5, -1, -2). For other positions use recurrence_position
                    """
            )
        }
        return EKRecurrenceDayOfWeek(day, weekNumber: number)
    }

    /// `days` without repeats, in the order given.
    static func unique(_ days: [EKRecurrenceDayOfWeek]) -> [EKRecurrenceDayOfWeek] {
        var seen = Set<[Int]>()
        return days.filter { seen.insert([$0.dayOfTheWeek.rawValue, $0.weekNumber]).inserted }
    }

    /// True when `key` was sent as null or an empty string, meaning "clear it".
    private static func isBlank(_ key: String, in args: Arguments) -> Bool {
        args.contains(key) && args.clearableString(key) == ""
    }

    /// A short human description for result payloads.
    static func describe(_ rule: EKRecurrenceRule) -> String {
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "period"
        }

        var text = rule.interval == 1 ? "every \(unit)" : "every \(rule.interval) \(unit)s"
        let days = rule.daysOfTheWeek ?? []
        let positions = (rule.setPositions ?? []).map(\.intValue)
        // A position picks among plain weekdays: "the last weekday", "the 2nd Tue".
        let positionsOnDays = !positions.isEmpty && !days.isEmpty && days.allSatisfy { $0.weekNumber == 0 }
        if positionsOnDays {
            text += " on the " + positions.map(ordinal).joined(separator: ", ") + " " + dayGroup(days)
        } else if !days.isEmpty {
            text += " on " + days.map(describe).joined(separator: ", ")
        }
        if let monthDays = rule.daysOfTheMonth, !monthDays.isEmpty {
            text += " on the " + monthDays.map { describeMonthDay($0.intValue) }.joined(separator: ", ")
        }
        if let months = rule.monthsOfTheYear, !months.isEmpty {
            // Fixed English names, like the weekdays': a Calendar with no locale
            // set gave "M11" in some processes.
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            text += " in " + months.compactMap { names[safe: $0.intValue - 1] }.joined(separator: ", ")
        }
        if !positions.isEmpty, !positionsOnDays {
            text += " (the " + positions.map(ordinal).joined(separator: ", ") + " of each \(unit))"
        }
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                text += ", \(end.occurrenceCount) times"
            } else if let until = end.endDate {
                text += ", until \(DateParsing.dateOnly.string(from: until))"
            }
        }
        return text
    }

    /// "Mon", or "2nd Tue" / "last Fri" for a weekday within a month or year.
    static func describe(_ day: EKRecurrenceDayOfWeek) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let name = names[safe: day.dayOfTheWeek.rawValue - 1] ?? "day"
        return day.weekNumber == 0 ? name : "\(ordinal(day.weekNumber)) \(name)"
    }

    /// The weekdays a position picks among: "weekday" for Monday to Friday,
    /// "weekend day", "day" for all seven, one day's name, or "of Mon, Wed".
    private static func dayGroup(_ days: [EKRecurrenceDayOfWeek]) -> String {
        let set = Set(days.map(\.dayOfTheWeek.rawValue))
        switch set {
        case [2, 3, 4, 5, 6]: return "weekday"
        case [1, 7]: return "weekend day"
        case Set(1...7): return "day"
        default:
            return days.count == 1 ? describe(days[0]) : "of " + days.map(describe).joined(separator: ", ")
        }
    }

    /// A day of the month: "15th", or "last day" / "2nd last day" from the end.
    private static func describeMonthDay(_ day: Int) -> String {
        day < 0 ? "\(ordinal(day)) day" : ordinal(day)
    }

    /// 1st, 2nd, 3rd, 11th, 21st; counted from the end when negative: last, 2nd last.
    static func ordinal(_ n: Int) -> String {
        if n == -1 { return "last" }
        if n < 0 { return "\(ordinal(-n)) last" }
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// ``describe(_:)`` for an item's first rule, or nil when it doesn't repeat.
    static func describe(_ item: EKCalendarItem) -> String? {
        item.recurrenceRules?.first.map(describe)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
