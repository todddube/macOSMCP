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

    /// - Returns: nil when the caller asked for no recurrence.
    static func rule(from args: Arguments) throws -> EKRecurrenceRule? {
        guard let raw = args.optionalString("recurrence") else { return nil }

        let frequency: EKRecurrenceFrequency
        switch raw.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        case "none": return nil
        default:
            throw MacBridgeError.invalidArgument(
                name: "recurrence",
                reason: "expected one of \(allowedFrequencies.joined(separator: ", ")) or none"
            )
        }

        let interval = try args.int("recurrence_interval", default: 1, in: 1...999)

        // count and until are mutually exclusive in EventKit; count wins if both
        // are supplied, since it is the less ambiguous of the two.
        var end: EKRecurrenceEnd?
        if let count = try args.optionalInt("recurrence_count", in: 1...9999) {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let until = try args.optionalDate("recurrence_until") {
            end = EKRecurrenceEnd(end: until.date)
        }

        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
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
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                text += ", \(end.occurrenceCount) times"
            } else if let until = end.endDate {
                text += ", until \(DateParsing.dateOnly.string(from: until))"
            }
        }
        return text
    }
}
