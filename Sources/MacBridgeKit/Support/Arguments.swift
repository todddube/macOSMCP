//
//  Arguments.swift
//  MacBridgeKit · MacBridge
//
//  Typed, validating access to a tool call's arguments.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// Typed, validating access to a tool call's arguments.
///
/// Every accessor throws `MacBridgeError.invalidArgument` with the offending
/// key named, so a model that guesses a parameter wrong gets a message it can
/// act on rather than a generic decode failure.
public struct Arguments {
    private let raw: [String: Value]

    /// Wraps a call's raw arguments; a call with none behaves as an empty object.
    public init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    /// Every key the caller supplied, including explicit nulls.
    public var keys: Set<String> { Set(raw.keys) }

    /// True when the caller supplied the key at all, even as null.
    public func contains(_ key: String) -> Bool { raw[key] != nil }

    /// True when the caller supplied the key with an explicit null, which the
    /// patch-semantics tools read as "clear this field".
    public func isExplicitNull(_ key: String) -> Bool {
        if case .some(.null) = raw[key] { return true }
        return false
    }

    // MARK: Strings

    /// The trimmed string, or nil when absent, null, not a string, or blank.
    public func optionalString(_ key: String) -> String? {
        guard let v = raw[key], let s = v.stringValue else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The trimmed string; throws when it is absent, not a string, or blank.
    public func requiredString(_ key: String) throws -> String {
        guard let v = raw[key] else { throw MacBridgeError.missingArgument(key) }
        guard let s = v.stringValue else {
            throw MacBridgeError.invalidArgument(name: key, reason: "expected a string")
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacBridgeError.invalidArgument(name: key, reason: "must not be empty")
        }
        return trimmed
    }

    /// A string that may be present-but-empty, meaning "clear it".
    /// Returns nil when absent, `""` when the caller asked to clear.
    public func clearableString(_ key: String) -> String? {
        if isExplicitNull(key) { return "" }
        guard let v = raw[key], let s = v.stringValue else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A URL, or nil when absent or blank. Throws when the text is not a URL with a
    /// scheme, rather than dropping it: a silently missing meeting link is worse
    /// than an error the model can fix.
    public func optionalURL(_ key: String) throws -> URL? {
        guard let text = optionalString(key) else { return nil }
        return try Self.parseURL(text, key: key)
    }

    /// ``clearableString(_:)`` for a URL: nil when absent, `.some(nil)` to clear.
    public func clearableURL(_ key: String) throws -> URL?? {
        guard let text = clearableString(key) else { return nil }
        if text.isEmpty { return .some(nil) }
        return .some(try Self.parseURL(text, key: key))
    }

    private static func parseURL(_ text: String, key: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else {
            throw MacBridgeError.invalidArgument(
                name: key,
                reason: "'\(text)' is not a URL; include the scheme, as in https://example.com"
            )
        }
        return url
    }

    // MARK: Numbers & booleans

    /// The largest magnitude accepted from a JSON number.
    ///
    /// `Value` decodes any JSON number too large for `Int` as a `.double`, and
    /// `Int(_: Double)` *traps* on anything out of range — so `{"limit": 1e30}`
    /// would crash the app that serves every connected client. Well beyond any
    /// legitimate count, limit or duration here.
    private static let numericLimit = 9_007_199_254_740_991.0  // 2^53 - 1

    /// An integer from a JSON number or a numeric string, or nil when absent.
    ///
    /// A fractional number is truncated toward zero.
    public func optionalInt(_ key: String) throws -> Int? {
        guard let v = raw[key] else { return nil }
        return try Self.integer(v, key: key)
    }

    /// One JSON number or numeric string as an integer; throws for anything else.
    private static func integer(_ v: Value, key: String) throws -> Int {
        if let i = v.intValue { return i }

        if let d = v.doubleValue {
            guard d.isFinite, abs(d) <= Self.numericLimit else {
                throw MacBridgeError.invalidArgument(
                    name: key,
                    reason: "\(d) is not a usable whole number"
                )
            }
            return Int(d)
        }

        if let s = v.stringValue, let i = Int(s) { return i }
        throw MacBridgeError.invalidArgument(name: key, reason: "expected an integer")
    }

    /// An optional integer that must fall inside `range`.
    ///
    /// Unlike `int(_:default:in:)` this rejects rather than clamps, because for a
    /// duration or an alarm offset a silently clamped value is worse than an error
    /// the model can correct.
    public func optionalInt(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = try optionalInt(key) else { return nil }
        guard range.contains(value) else {
            throw MacBridgeError.invalidArgument(
                name: key,
                reason: "must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return value
    }

    /// An integer clamped into `range`, falling back to `fallback` when absent.
    public func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let i = try optionalInt(key) else { return fallback }
        return min(max(i, range.lowerBound), range.upperBound)
    }

    /// A boolean from JSON `true`/`false`, a number, or `"true"`/`"yes"`/`"1"` and
    /// their opposites, since models often send booleans as strings.
    public func optionalBool(_ key: String) throws -> Bool? {
        guard let v = raw[key] else { return nil }
        if let b = v.boolValue { return b }
        if let s = v.stringValue {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        }
        if let i = v.intValue { return i != 0 }
        throw MacBridgeError.invalidArgument(name: key, reason: "expected a boolean")
    }

    /// ``optionalBool(_:)`` with a default for when the key is absent.
    public func bool(_ key: String, default fallback: Bool) throws -> Bool {
        try optionalBool(key) ?? fallback
    }

    // MARK: Dates

    /// A date parsed by ``DateParsing``, or nil when absent or blank.
    ///
    /// `hasTime` is false for date-only input such as `2026-10-01` or `tomorrow`,
    /// which callers use to decide between all-day and timed handling.
    ///
    /// - Parameter timeZone: the zone a date-time without an offset is wall-clock
    ///   time in; nil for the Mac's. See ``DateParsing/parse(_:now:timeZone:)``.
    public func optionalDate(_ key: String, timeZone: TimeZone? = nil) throws -> (date: Date, hasTime: Bool)? {
        // A number or boolean is a mistake, not an absent value: ignoring it would
        // let a call succeed while silently dropping what the caller asked for.
        try Self.requireStringOrNull(raw[key], key: key)
        guard let s = optionalString(key) else { return nil }
        guard let parsed = DateParsing.parse(s, timeZone: timeZone) else {
            throw MacBridgeError.invalidArgument(
                name: key,
                reason: "could not read '\(s)' as a date. Use YYYY-MM-DD, YYYY-MM-DDTHH:MM[:SS], "
                    + "an ISO-8601 timestamp, or a relative value like 'today', 'tomorrow', '+7d', "
                    + "'+2h' or '+30min' (months are '+1mo'; '+1m' is ambiguous and not accepted)."
            )
        }
        return parsed
    }

    /// A date that may be cleared: nil when the key is absent, `.some(nil)` for an
    /// explicit null or an empty string, `.some(date)` otherwise. Anything that is
    /// not a string (a number, a boolean) or a blank-but-not-empty string throws,
    /// so it can never be mistaken for a request to clear.
    public func clearableDate(_ key: String) throws -> (date: Date, hasTime: Bool)?? {
        guard let value = raw[key] else { return nil }
        if case .null = value { return .some(nil) }
        guard let text = value.stringValue else {
            throw MacBridgeError.invalidArgument(name: key, reason: Self.dateStringAdvice)
        }
        if text.isEmpty { return .some(nil) }
        guard optionalString(key) != nil else {
            throw MacBridgeError.invalidArgument(
                name: key,
                reason: "is blank. Pass a date string to set it, or null or \"\" to clear it."
            )
        }
        return .some(try optionalDate(key))
    }

    private static let dateStringAdvice =
        "expected a date string such as 2026-10-01 or 2026-10-01T14:00:00 (not a number or boolean); "
        + "pass null or \"\" to clear it"

    private static func requireStringOrNull(_ value: Value?, key: String) throws {
        guard let value else { return }
        if case .null = value { return }
        guard value.stringValue != nil else {
            throw MacBridgeError.invalidArgument(name: key, reason: dateStringAdvice)
        }
    }

    /// ``optionalDate(_:timeZone:)``, but throws when the key is absent or blank.
    public func requiredDate(_ key: String, timeZone: TimeZone? = nil) throws -> (date: Date, hasTime: Bool) {
        guard contains(key) else { throw MacBridgeError.missingArgument(key) }
        guard let parsed = try optionalDate(key, timeZone: timeZone) else {
            throw MacBridgeError.invalidArgument(name: key, reason: "expected a date string")
        }
        return parsed
    }

    // MARK: Time zones

    /// An IANA time zone such as `America/New_York`, or nil when absent.
    ///
    /// Matched case-insensitively against the identifiers the system knows, plus
    /// `UTC` and `GMT`. Abbreviations such as `EST` are refused rather than
    /// guessed: they don't say whether daylight saving applies, and several are
    /// used by more than one region. Null or blank throws, because there is no
    /// zone to clear to.
    public func optionalTimeZone(_ key: String) throws -> TimeZone? {
        guard let value = raw[key] else { return nil }
        let advice = "use an IANA time zone identifier such as America/New_York, Europe/London, "
            + "Asia/Tokyo or UTC (not an abbreviation like EST or an offset like +05:00)"
        guard let text = optionalString(key) else {
            if value.stringValue != nil || value == .null {
                throw MacBridgeError.invalidArgument(name: key, reason: "is empty; \(advice)")
            }
            throw MacBridgeError.invalidArgument(name: key, reason: "expected a string; \(advice)")
        }
        guard let zone = Self.timeZone(identifier: text) else {
            throw MacBridgeError.invalidArgument(name: key, reason: "'\(text)' is not a known time zone; \(advice)")
        }
        return zone
    }

    /// The zone for an IANA identifier in any letter case; nil for anything else.
    static func timeZone(identifier text: String) -> TimeZone? {
        let wanted = text.lowercased()
        if wanted == "utc" || wanted == "gmt" { return TimeZone(identifier: text.uppercased()) }
        guard let known = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased() == wanted }) else {
            return nil
        }
        return TimeZone(identifier: known)
    }

    // MARK: Arrays

    /// A list of strings that may be cleared: nil when the key is absent, `[]` for
    /// null, `""` or an empty array, the trimmed items otherwise. A bare string is a
    /// one-item list. A blank or non-string item throws rather than being dropped.
    public func clearableStringList(_ key: String) throws -> [String]? {
        guard let value = raw[key] else { return nil }
        if case .null = value { return [] }
        if let text = value.stringValue, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try (value.arrayValue ?? [value]).map { item in
            guard let text = item.stringValue else {
                throw MacBridgeError.invalidArgument(name: key, reason: "expected a list of strings")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MacBridgeError.invalidArgument(name: key, reason: "contains a blank item")
            }
            return trimmed
        }
    }

    /// A list of integers that may be cleared: nil when the key is absent, `[]` for
    /// null, `""` or an empty array, the items otherwise. A bare number is a
    /// one-item list. An item that isn't a whole number throws.
    public func clearableIntList(_ key: String) throws -> [Int]? {
        guard let value = raw[key] else { return nil }
        if case .null = value { return [] }
        if let text = value.stringValue, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        do {
            return try (value.arrayValue ?? [value]).map { try Self.integer($0, key: key) }
        } catch {
            throw MacBridgeError.invalidArgument(name: key, reason: "expected a list of whole numbers")
        }
    }

    /// Non-blank trimmed strings from an array, or a single string as a one-element
    /// list; nil when absent or nothing usable remains.
    public func optionalStringArray(_ key: String) -> [String]? {
        guard let v = raw[key] else { return nil }
        if let arr = v.arrayValue {
            let strings = arr.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return strings.isEmpty ? nil : strings
        }
        // Tolerate a single string where a list is expected.
        if let s = optionalString(key) { return [s] }
        return nil
    }
}
