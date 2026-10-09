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

    // MARK: Reused fragments

    /// The date format blurb, repeated so each parameter is self-documenting
    /// without the model having to read the server instructions.
    public static let dateFormats =
        "Accepts YYYY-MM-DD, YYYY-MM-DDTHH:MM:SS, a full ISO-8601 timestamp, "
        + "or a relative value: today, tomorrow, yesterday, now, +7d, -3d, +2w."
}
