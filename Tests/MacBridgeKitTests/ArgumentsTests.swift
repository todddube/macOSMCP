//
//  ArgumentsTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Argument coercion, and reminder priority mapping.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// `Arguments` is the boundary where a model's guesses meet EventKit. Its job is
/// to coerce what is reasonable and reject what is not, with a message naming the
/// offending key — both halves are tested here.
@Suite("Argument coercion")
struct ArgumentsTests {

    @Test("Required strings are trimmed, and blanks are rejected")
    func requiredStrings() throws {
        let args = Arguments(["title": .string("  Buy milk  "), "blank": .string("   ")])
        #expect(try args.requiredString("title") == "Buy milk")

        #expect(throws: MacBridgeError.self) {
            _ = try args.requiredString("blank")
        }
        #expect(throws: MacBridgeError.missingArgument("absent")) {
            _ = try args.requiredString("absent")
        }
    }

    @Test("Optional strings treat empty as absent")
    func optionalStrings() {
        let args = Arguments(["a": .string(""), "b": .string("  x  ")])
        #expect(args.optionalString("a") == nil, "an empty string is not a value")
        #expect(args.optionalString("b") == "x")
        #expect(args.optionalString("missing") == nil)
    }

    @Test("Explicit null is distinguished from absent, so fields can be cleared")
    func explicitNull() {
        let args = Arguments(["notes": .null])
        #expect(args.contains("notes"), "an explicit null is still present")
        #expect(args.isExplicitNull("notes"))
        #expect(!args.isExplicitNull("other"))
        #expect(args.clearableString("notes") == "", "null means clear")
    }

    @Test("Booleans accept the spellings models actually emit", arguments: [
        (Value.bool(true), true),
        (.string("yes"), true),
        (.string("TRUE"), true),
        (.string("FALSE"), false),
        (.string("no"), false),
        (.int(1), true),
        (.int(0), false),
    ])
    func booleanCoercion(input: Value, expected: Bool) throws {
        #expect(try Arguments(["flag": input]).optionalBool("flag") == expected)
    }

    @Test("A non-boolean is rejected rather than coerced")
    func badBoolean() {
        #expect(throws: MacBridgeError.self) {
            _ = try Arguments(["flag": .string("maybe")]).optionalBool("flag")
        }
    }

    @Test("Integers accept numeric strings and clamp to the declared range")
    func integers() throws {
        let args = Arguments(["n": .int(5), "s": .string("42"), "huge": .int(9999), "neg": .int(-3)])
        #expect(try args.optionalInt("n") == 5)
        #expect(try args.optionalInt("s") == 42, "a numeric string is worth coercing, not rejecting")
        #expect(try args.int("huge", default: 50, in: 1...500) == 500, "clamped to the maximum")
        #expect(try args.int("neg", default: 50, in: 1...500) == 1, "clamped to the minimum")
        #expect(try args.int("absent", default: 50, in: 1...500) == 50)
    }

    @Test("A bad integer names the key it came from")
    func badIntegerNamesKey() {
        do {
            _ = try Arguments(["limit": .string("lots")]).optionalInt("limit")
            Issue.record("'lots' is not an integer")
        } catch let error as MacBridgeError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("limit"), "the message should name the key: \(message)")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("An out-of-range JSON number is refused rather than trapping", arguments: [
        1e30, -1e30, 1e300, Double.infinity, -Double.infinity, Double.nan,
    ])
    func hugeNumbersDoNotTrap(value: Double) {
        // `Value` decodes any JSON number too large for Int as a .double, and
        // Int(_: Double) traps out of range — which would take down the app that
        // serves every connected client, not just the offending request.
        #expect(throws: MacBridgeError.self) {
            _ = try Arguments(["limit": .double(value)]).optionalInt("limit")
        }
    }

    @Test("A double that fits is still accepted")
    func representableDoublesStillWork() throws {
        #expect(try Arguments(["limit": .double(42)]).optionalInt("limit") == 42)
        #expect(try Arguments(["limit": .double(-7)]).optionalInt("limit") == -7)
    }

    @Test("A bounded integer rejects out-of-range values instead of clamping")
    func boundedIntegers() throws {
        let args = Arguments(["minutes": .int(50_000_000), "ok": .int(30)])
        #expect(try args.optionalInt("ok", in: 1...1440) == 30)
        #expect(throws: MacBridgeError.self) {
            _ = try args.optionalInt("minutes", in: 1...1440)
        }
        #expect(try args.optionalInt("absent", in: 1...1440) == nil)
    }

    @Test("Extreme minute values cannot overflow a TimeInterval computation")
    func extremeMinutesRejected() {
        // abs(Int.min) and minutes * 60 both trap; these reach the services as
        // alarm_minutes_before and duration_minutes.
        for value in [Int.min, Int.max] {
            #expect(throws: MacBridgeError.self) {
                _ = try Arguments(["minutes": .int(value)]).optionalInt("minutes", in: 0...525_600)
            }
        }
    }

    @Test("A string list accepts a bare string as well as an array")
    func stringLists() {
        let asArray = Arguments(["calendars": .array([.string("Work"), .string("Home")])])
        #expect(asArray.optionalStringArray("calendars") == ["Work", "Home"])

        let asString = Arguments(["calendars": .string("Work")])
        #expect(asString.optionalStringArray("calendars") == ["Work"])

        #expect(Arguments([:]).optionalStringArray("calendars") == nil)
        #expect(
            Arguments(["calendars": .array([])]).optionalStringArray("calendars") == nil,
            "an empty array is the same as not filtering"
        )
    }

    @Test("Dates flow through the shared parser and report bad input clearly")
    func dates() throws {
        let args = Arguments(["due": .string("2026-09-28"), "bad": .string("someday")])
        let due = try #require(try args.optionalDate("due"))
        #expect(due.hasTime == false)

        do {
            _ = try args.optionalDate("bad")
            Issue.record("'someday' is not a date")
        } catch let error as MacBridgeError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("bad"), "the message should name the key")
            #expect(message.contains("YYYY-MM-DD"), "the message should show the accepted formats")
        }
    }
}

/// Priority is the one field with three spellings in play: what a user says
/// ("high"), what EventKit stores (1–9), and what Reminders.app displays.
@Suite("Reminder priority mapping")
struct PriorityTests {

    @Test("Words map to the values Reminders.app itself writes", arguments: [
        ("high", 1), ("medium", 5), ("med", 5), ("low", 9), ("none", 0),
    ])
    func words(word: String, expected: Int) throws {
        #expect(try ReminderMapping.parsePriority(Arguments(["priority": .string(word)])) == expected)
    }

    @Test("Raw numbers pass through, and out-of-range values are rejected")
    func numbers() throws {
        #expect(try ReminderMapping.parsePriority(Arguments(["priority": .int(4)])) == 4)
        #expect(throws: MacBridgeError.self) {
            _ = try ReminderMapping.parsePriority(Arguments(["priority": .int(42)]))
        }
        #expect(throws: MacBridgeError.self) {
            _ = try ReminderMapping.parsePriority(Arguments(["priority": .string("urgent")]))
        }
    }

    @Test("An absent priority is left alone, but an explicit null clears it")
    func absentVersusNull() throws {
        #expect(try ReminderMapping.parsePriority(Arguments([:])) == nil, "absent means do not touch")
        #expect(try ReminderMapping.parsePriority(Arguments(["priority": .null])) == 0, "null means clear")
    }

    @Test("Labels round-trip the whole 0–9 range into the three levels")
    func labels() {
        #expect(ReminderMapping.priorityLabel(0) == "none")
        #expect((1...4).allSatisfy { ReminderMapping.priorityLabel($0) == "high" })
        #expect(ReminderMapping.priorityLabel(5) == "medium")
        #expect((6...9).allSatisfy { ReminderMapping.priorityLabel($0) == "low" })
    }
}
