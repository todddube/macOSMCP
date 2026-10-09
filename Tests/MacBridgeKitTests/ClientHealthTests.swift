//
//  ClientHealthTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The precedence behind the green/yellow/red client indicators.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// Which colour wins when several things are wrong with a client at once.
@Suite("Client health")
struct ClientHealthTests {

    private func health(
        setup: ClientSetup.Status? = .ready,
        connected: Bool = true,
        listening: Bool = true,
        missing: [String] = [],
        failed: Bool = false
    ) -> ClientHealth {
        ClientHealth.evaluate(
            setup: setup, connected: connected, bridgeListening: listening,
            missingDomains: missing, totalDomains: 2, lastCallFailed: failed
        )
    }

    @Test func connectedAndGrantedIsGood() {
        #expect(health().level == .good)
    }

    @Test func notInstalledAndIdleIsAbsent() {
        #expect(health(setup: .notInstalled, connected: false).level == .absent)
    }

    @Test func stoppedBridgeIsAProblemEvenWhenConnected() {
        #expect(health(listening: false).level == .problem)
    }

    @Test func noPermissionsAtAllIsAProblem() {
        #expect(health(missing: ["Calendar", "Reminders"]).level == .problem)
    }

    @Test func partialPermissionsWarn() {
        let result = health(missing: ["Reminders"])
        #expect(result.level == .warning)
        #expect(result.reason.contains("Reminders"))
    }

    @Test func aFailedLastCallWarns() {
        #expect(health(failed: true).level == .warning)
    }

    /// A project-level `.mcp.json` connection is invisible to config detection, but
    /// the live connection proves it works.
    @Test func liveConnectionBeatsConfigDetection() {
        #expect(health(setup: .notConfigured, connected: true).level == .good)
    }

    @Test func idleButConfiguredWarns() {
        #expect(health(connected: false).level == .warning)
    }

    @Test func idleAndPointingElsewhereIsAProblem() {
        #expect(health(setup: .pointsElsewhere("/tmp/other/macbridge"), connected: false).level == .problem)
    }

    @Test func idleAndNotConfiguredWarns() {
        #expect(health(setup: .notConfigured, connected: false).level == .warning)
    }
}
