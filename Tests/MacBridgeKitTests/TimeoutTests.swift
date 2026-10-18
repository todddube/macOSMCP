//
//  TimeoutTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The time limit on permission requests, and how waiting requests are shared.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// ``Timeout`` with stand-in operations; no EventKit.
@Suite("Timeout")
struct TimeoutTests {

    private struct Failure: Error {}

    @Test("An answer before the limit is returned")
    func answers() async throws {
        let value = try await Timeout.run(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("An operation that never answers gives nil at the limit, not a hang")
    func timesOut() async throws {
        let started = Date()
        let value: Int? = try await Timeout.run(seconds: 0.2) {
            // Stands in for a permission request whose prompt never appears.
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("The operation's error comes through")
    func throwsThrough() async {
        await #expect(throws: Failure.self) {
            _ = try await Timeout.run(seconds: 5) { () async throws -> Int in throw Failure() }
        }
    }

    @Test("Cancelling the caller stops the wait at once")
    func cancellation() async {
        let waiting = Task {
            try await Timeout.run(seconds: 60) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return 1
            }
        }
        waiting.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

/// ``InFlightRequests`` with stand-in requests; no EventKit.
@Suite("Shared permission requests")
struct InFlightRequestsTests {

    /// Counts how many requests were actually made.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("Calls on one store share the waiting request; another store asks for itself")
    func sharing() async throws {
        let requests = InFlightRequests()
        let made = Counter()
        // Held for the whole test: a freed object's address can be reused, and two
        // stores at one address would look like one store.
        let objectA = NSObject(), objectB = NSObject()
        let storeA = ObjectIdentifier(objectA), storeB = ObjectIdentifier(objectB)
        defer { withExtendedLifetime((objectA, objectB)) {} }
        let slow: @Sendable () async throws -> Bool = {
            made.increment()
            try await Task.sleep(nanoseconds: 200_000_000)
            return true
        }

        let first = requests.request(for: .calendar, on: storeA, make: slow)
        let second = requests.request(for: .calendar, on: storeA, make: slow)
        let other = requests.request(for: .calendar, on: storeB, make: slow)
        let reminders = requests.request(for: .reminders, on: storeA, make: slow)

        _ = try await (first.value, second.value, other.value, reminders.value)
        #expect(made.count == 3)
    }

    @Test("An answered request is forgotten, so the next call asks again")
    func forgetsAnswered() async throws {
        let requests = InFlightRequests()
        let object = NSObject()
        let store = ObjectIdentifier(object)
        defer { withExtendedLifetime(object) {} }
        _ = try await requests.request(for: .calendar, on: store) { true }.value
        // finish runs in the task's defer, just after the value is delivered.
        for _ in 0..<50 where requests.count > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(requests.count == 0)
    }
}
