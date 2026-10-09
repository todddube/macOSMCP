//
//  ClientHealth.swift
//  MacBridgeKit · MacBridge
//
//  Decides the green/yellow/red indicator shown for each AI client.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// How a single AI client's connection to MacBridge is doing, as one colour and
/// the reason behind it.
///
/// Pure and EventKit-free so the precedence below is testable. The app gathers
/// the inputs and draws the result as the dots under the menu-bar icon.
public struct ClientHealth: Sendable, Equatable {

    /// The indicator colour, from best to worst, plus `absent` for no indicator.
    public enum Level: Sendable, Equatable {
        /// Connected and working.
        case good
        /// Installed but not connected right now, set up or not. An ordinary state,
        /// such as Claude Desktop being closed: shown green, since nothing is wrong,
        /// but steady rather than breathing.
        case standby
        /// Connected, but something needs a look: partial permissions, or the last
        /// call failed.
        case warning
        /// Calls cannot succeed until something is fixed.
        case problem
        /// The client is not installed, so there is nothing to report.
        case absent
    }

    public let level: Level
    /// One line explaining `level`, shown as the indicator's tooltip and menu text.
    public let reason: String

    public init(level: Level, reason: String) {
        self.level = level
        self.reason = reason
    }

    /// The health of one client.
    ///
    /// The order of the checks matters. A live connection beats whatever the config
    /// detection says: a client can be wired up through a project's `.mcp.json`,
    /// which `ClientSetup` does not read, and a working connection is the proof
    /// that counts. Only a stopped bridge or no permissions at all override it,
    /// because then no call can succeed.
    ///
    /// - Parameters:
    ///   - setup: What the client's config file says, if it was checked.
    ///   - connected: Whether a shim for this client is connected right now.
    ///   - bridgeListening: Whether the app's socket server is up.
    ///   - missingDomains: Display names of domains without full access.
    ///   - totalDomains: How many domains MacBridge serves.
    ///   - lastCallFailed: Whether this client's most recent call failed.
    public static func evaluate(
        setup: ClientSetup.Status?,
        connected: Bool,
        bridgeListening: Bool,
        missingDomains: [String],
        totalDomains: Int,
        lastCallFailed: Bool
    ) -> ClientHealth {
        if setup == .notInstalled && !connected {
            return ClientHealth(level: .absent, reason: "Not installed")
        }
        guard bridgeListening else {
            return ClientHealth(level: .problem, reason: "Bridge is not running")
        }
        if totalDomains > 0 && missingDomains.count >= totalDomains {
            return ClientHealth(level: .problem, reason: "No Calendar or Reminders access")
        }

        if connected {
            if lastCallFailed {
                return ClientHealth(level: .warning, reason: "Connected — last call failed")
            }
            if let missing = missingDomains.first {
                return ClientHealth(level: .warning, reason: "Connected — no \(missing) access")
            }
            return ClientHealth(level: .good, reason: "Connected")
        }

        switch setup {
        case .pointsElsewhere:
            return ClientHealth(level: .problem, reason: "Configured for another copy")
        case .notConfigured:
            return ClientHealth(level: .standby, reason: "Not set up")
        case .ready, .notInstalled, nil:
            return ClientHealth(level: .standby, reason: "Set up — not connected")
        }
    }
}
