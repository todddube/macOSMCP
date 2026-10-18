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
/// ask for ("every week", "every 2 weeks, 10 times").
enum Recurrence {

    static let allowedFrequencies = ["daily", "weekly", "monthly", "yearly"]

    /// Every argument that describes a repeat.
    static let argumentNames: Set<String> = [
        "recurrence", "recurrence_interval", "recurrence_count", "recurrence_until",
    ]

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
    /// - Returns: nil when the caller asked for no recurrence.
    static func rule(from args: Arguments) throws -> EKRecurrenceRule? {
        guard case .set(let rule) = try change(from: args, existing: nil) else { return nil }
        return rule
    }

    /// The repeat an update asks for, or nil when it doesn't mention one.
    ///
    /// Parts not given are kept from `existing`, so "make it every 2 weeks" keeps
    /// the weekly frequency and "stop after 10 times" keeps both. A new frequency
    /// starts afresh, because an end chosen for a daily repeat means something else
    /// for a monthly one.
    ///
    /// - Parameter splitsSeries: true when the change starts a new series at a
    ///   later occurrence (span `future_events`). An end kept as a count would then
    ///   count afresh from there, so a series of 10 changed at the 6th would run to
    ///   15; the caller is asked to restate the end instead.
    static func change(
        from args: Arguments,
        existing: EKRecurrenceRule?,
        splitsSeries: Bool = false
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
        guard let base else {
            return .set(EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end))
        }
        return .set(EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: base.daysOfTheWeek,
            daysOfTheMonth: base.daysOfTheMonth,
            monthsOfTheYear: base.monthsOfTheYear,
            weeksOfTheYear: base.weeksOfTheYear,
            daysOfTheYear: base.daysOfTheYear,
            setPositions: base.setPositions,
            end: end
        ))
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
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            text += " on " + days.map(describe).joined(separator: ", ")
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            text += " on the " + days.map { ordinal($0.intValue) }.joined(separator: ", ")
        }
        if let months = rule.monthsOfTheYear, !months.isEmpty {
            let names = Calendar(identifier: .gregorian).shortMonthSymbols
            text += " in " + months.compactMap { names[safe: $0.intValue - 1] }.joined(separator: ", ")
        }
        if let positions = rule.setPositions, !positions.isEmpty {
            text += " (the " + positions.map { ordinal($0.intValue) }.joined(separator: ", ") + " of each \(unit))"
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
    private static func describe(_ day: EKRecurrenceDayOfWeek) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let name = names[safe: day.dayOfTheWeek.rawValue - 1] ?? "day"
        return day.weekNumber == 0 ? name : "\(ordinal(day.weekNumber)) \(name)"
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
