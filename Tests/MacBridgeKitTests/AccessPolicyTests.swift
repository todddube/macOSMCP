//
//  AccessPolicyTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Read-only mode and confirmation before deleting.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import Testing

@testable import MacBridgeKit

/// The policy decides before any EventKit access, so none of this touches data.
@Suite("Access policy")
struct AccessPolicyTests {

    @Test("By default everything runs, and deleting is confirmed")
    func defaults() {
        let policy = AccessPolicy()
        #expect(policy.decision(for: "calendar_create_event", arguments: nil) == .allow)
        #expect(policy.decision(for: "reminders_search_reminders", arguments: nil) == .allow)
        for tool in ToolRegistry.destructiveToolNames {
            #expect(policy.decision(for: tool, arguments: nil) == .confirm, "\(tool) should be confirmed")
        }
    }

    @Test("Read-only refuses every tool that changes data, and only those")
    func readOnly() {
        let policy = AccessPolicy(readOnly: true)
        for tool in ToolRegistry.definitions() {
            let decision = policy.decision(for: tool.name, arguments: nil)
            if tool.annotations.readOnlyHint == true || tool.name.contains("_open_") {
                #expect(decision == .allow, "\(tool.name) only reads and should still run")
            } else {
                guard case .refuse(let message) = decision else {
                    Issue.record("\(tool.name) changes data and should be refused")
                    continue
                }
                #expect(message.contains(tool.name))
                #expect(message.contains("nothing was changed"))
            }
        }
    }

    @Test("Changing an event's repeat is held for confirmation; other edits aren't")
    func repeatChange() {
        let policy = AccessPolicy()
        #expect(policy.decision(for: "calendar_update_event", arguments: ["title": .string("x")]) == .allow)
        #expect(policy.decision(for: "calendar_update_event", arguments: ["recurrence": .string("none")]) == .confirm)
        #expect(policy.decision(for: "calendar_update_event", arguments: ["recurrence_count": .int(3)]) == .confirm)
        // A reminder's repeat removes nothing.
        #expect(policy.decision(for: "reminders_update_reminder", arguments: ["recurrence": .string("none")]) == .allow)
        #expect(AccessPolicy(confirmDestructive: false)
            .decision(for: "calendar_update_event", arguments: ["recurrence": .string("none")]) == .allow)
    }

    @Test("Turning off confirmation lets deletes through")
    func noConfirmation() {
        let policy = AccessPolicy(confirmDestructive: false)
        #expect(policy.decision(for: "reminders_delete_list", arguments: nil) == .allow)
    }

    @Test("The policy round-trips through defaults, and a missing key keeps confirmation on")
    func storage() throws {
        let suite = "AccessPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AccessPolicy.load(from: defaults) == AccessPolicy())

        let changed = AccessPolicy(readOnly: true, confirmDestructive: false)
        changed.save(to: defaults)
        #expect(AccessPolicy.load(from: defaults) == changed)
    }
}
