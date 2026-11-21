//
//  Schema.swift
//  MacBridgeKit · MacBridge
//
//  Terse builders for the JSON Schema fragments tool definitions need.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// Terse builders for the JSON Schema fragments tool definitions need.
///
/// MCP takes schemas as `Value`, which is expressive but verbose to write by
/// hand; these keep the tool definitions readable enough to review as a spec.
public enum Schema {

    /// An object schema; `required` is omitted from the output when empty.
    public static func object(properties: [String: Value], required: [String] = []) -> Value {
        var out: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            out["required"] = .array(required.map { .string($0) })
        }
        return .object(out)
    }

    /// A string property, restricted to `options` when given.
    public static func string(_ description: String, options: [String]? = nil) -> Value {
        var out: [String: Value] = [
            "type": .string("string"),
            "description": .string(description),
        ]
        if let options {
            out["enum"] = .array(options.map { .string($0) })
        }
        return .object(out)
    }

    /// An integer property with an optional default and bounds.
    public static func integer(
        _ description: String,
        default defaultValue: Int? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> Value {
        var out: [String: Value] = [
            "type": .string("integer"),
            "description": .string(description),
        ]
        if let defaultValue { out["default"] = .int(defaultValue) }
        if let minimum { out["minimum"] = .int(minimum) }
        if let maximum { out["maximum"] = .int(maximum) }
        return .object(out)
    }

    /// A boolean property with an optional default.
    public static func boolean(_ description: String, default defaultValue: Bool? = nil) -> Value {
        var out: [String: Value] = [
            "type": .string("boolean"),
            "description": .string(description),
        ]
        if let defaultValue { out["default"] = .bool(defaultValue) }
        return .object(out)
    }

    /// A list of strings that also accepts a bare string, which models produce
    /// often enough that rejecting it would just cost a retry.
    public static func stringList(_ description: String) -> Value {
        .object([
            "description": .string(description),
            "oneOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
        ])
    }

    /// An array property whose items match `items`.
    public static func array(_ description: String, items: Value) -> Value {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    /// A property of a given JSON type (or several, such as `["string", "null"]`),
    /// for output schemas, where values aren't restricted the way inputs are.
    public static func typed(_ types: String..., description: String) -> Value {
        .object([
            "type": types.count == 1 ? .string(types[0]) : .array(types.map { .string($0) }),
            "description": .string(description),
        ])
    }

    // MARK: Reused fragments

    /// The date format blurb, repeated so each parameter is self-documenting
    /// without the model having to read the server instructions.
    public static let dateFormats =
        "Accepts YYYY-MM-DD, YYYY-MM-DDTHH:MM[:SS] (local time), a full ISO-8601 timestamp, "
        + "or a relative value: today, tomorrow, yesterday, now, +7d, -3d, +2w, +1mo, +2h, +30min."

    /// `recurrence_days`, shared by the event and reminder create and update tools.
    static let recurrenceDays = array(
        "Days the repeat falls on: monday…sunday or mon…sun. Weekly: plain days, e.g. [\"mon\", \"wed\", \"fri\"]. "
            + "Monthly or yearly: may take an ordinal, 1st to 5th, last or second-to-last, e.g. "
            + "[\"2nd tuesday\"] or [\"last fri\"]; a yearly one falls in the start's month. Not for daily "
            + "(use weekly). Choose a start that matches. Replaces recurrence_month_days; null or [] clears.",
        items: .object(["type": .string("string")])
    )

    /// `recurrence_position`, shared like ``recurrenceDays``.
    static let recurrencePosition = integer(
        "Monthly or yearly with plain recurrence_days: which matching day in the period, 1 to 5, or -1 "
            + "(last) to -5. Days mon–fri with -1 is the last weekday of the month. Null clears.",
        minimum: -5,
        maximum: 5
    )

    /// `recurrence_month_days`, shared like ``recurrenceDays``.
    static let recurrenceMonthDays = array(
        "Monthly only: days of the month, 1 to 31, or -1 (last day) to -31, e.g. [15, -1] for the 15th "
            + "and the last day. Choose a start that matches. Replaces recurrence_days; null or [] clears.",
        items: .object(["type": .string("integer")])
    )
}
