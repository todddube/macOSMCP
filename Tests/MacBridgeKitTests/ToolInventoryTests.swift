//
//  ToolInventoryTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The tool inventory and schema contract that clients see.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// Guards the contract clients see: the tool inventory and its schemas.
///
/// These catch mistakes that are invisible locally but break a model — a required
/// parameter missing from `properties`, a tool with no description, or a
/// destructive tool that forgot to say so and would therefore slip past the
/// planned confirmation gate.
@Suite("Tool inventory")
struct ToolInventoryTests {

    let tools = ToolRegistry.definitions()

    @Test("The expected 18 tools are present, 8 calendar and 10 reminders")
    func inventorySize() {
        #expect(tools.count == 18)
        #expect(tools.filter { $0.name.hasPrefix("calendar_") }.count == 8)
        #expect(tools.filter { $0.name.hasPrefix("reminders_") }.count == 10)
    }

    @Test("Tool names are unique")
    func uniqueNames() {
        #expect(Set(tools.map(\.name)).count == tools.count)
    }

    @Test("Every tool follows the domain_verb_object convention")
    func naming() {
        for tool in tools {
            #expect(ToolRegistry.domain(of: tool.name) != nil, "'\(tool.name)' has no known domain prefix")
            #expect(tool.name == tool.name.lowercased(), "'\(tool.name)' should be lowercase")
            #expect(!tool.name.contains(" "), "'\(tool.name)' should be snake_case")
        }
    }

    @Test("Every tool has a description that tells a model when to use it")
    func descriptions() {
        for tool in tools {
            #expect((tool.description ?? "").count > 40, "'\(tool.name)' needs a fuller description")
        }
    }

    @Test("Schemas are objects, and every required key is a declared property")
    func schemaIntegrity() throws {
        for tool in tools {
            let schema = try #require(tool.inputSchema.objectValue, "'\(tool.name)' schema is not an object")
            #expect(schema["type"]?.stringValue == "object", "'\(tool.name)' schema type")

            let properties = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(properties.contains(key), "'\(tool.name)' requires '\(key)' but never declares it")
            }
        }
    }

    @Test("Every property documents itself")
    func propertyDescriptions() {
        for tool in tools {
            for (name, schema) in tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:] {
                let described = schema.objectValue?["description"]?.stringValue?.isEmpty == false
                    || schema.objectValue?["oneOf"] != nil
                #expect(described, "'\(tool.name).\(name)' has no description")
            }
        }
    }

    @Test("Exactly the three data-destroying tools carry destructiveHint")
    func destructiveSet() {
        #expect(ToolRegistry.destructiveToolNames == [
            "calendar_cancel_event", "reminders_delete_reminder", "reminders_delete_list",
        ])
    }

    @Test("Read-only tools are never also marked destructive")
    func readOnlyIsNotDestructive() {
        for tool in tools where tool.annotations.readOnlyHint == true {
            #expect(tool.annotations.destructiveHint != true, "'\(tool.name)' cannot be both")
        }
    }

    @Test("Write tools that target an item declare its id required")
    func idsAreRequired() {
        // Read tools are exempt: reminders_search_reminders takes reminder_id as
        // an optional filter, not as a target to mutate.
        for tool in tools where tool.annotations.readOnlyHint != true {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            let required = Set(tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            for key in ["event_id", "reminder_id"] where properties[key] != nil {
                #expect(required.contains(key), "'\(tool.name)' should require '\(key)'")
            }
        }
    }
}

/// Routing by tool name, checked without touching EventKit.
@Suite("Dispatch")
struct DispatchTests {

    @Test("An unknown tool name is refused before any EventKit access")
    func unknownTool() async {
        let registry = ToolRegistry()
        await #expect(throws: MacBridgeError.unknownTool("calendar_does_not_exist")) {
            _ = try await registry.call("calendar_does_not_exist", arguments: [:])
        }
    }

    @Test("Every advertised tool is routed, and nothing extra is")
    func routesMatchInventory() async {
        // Compares the inventory against the registry's handler table, so a tool
        // that is advertised but never wired up is caught here rather than when a
        // model first calls it. Touches no EventKit API, so prompts nothing.
        let registry = ToolRegistry()
        let routed = await registry.routedToolNames
        #expect(routed == Set(ToolRegistry.definitions().map(\.name)))
    }
}

/// Argument names are checked before any handler runs, so these touch no EventKit.
@Suite("Argument names")
struct ArgumentNameTests {

    @Test("A misspelt name is refused with the likely intended one")
    func misspeltNameIsRefused() async {
        let registry = ToolRegistry()
        await #expect(throws: MacBridgeError.self) {
            _ = try await registry.call("reminders_create_reminder", arguments: [
                "title": .string("Pay rent"), "due_date": .string("tomorrow"),
            ])
        }
        do {
            try ToolRegistry.checkArgumentNames(
                tool: "reminders_create_reminder",
                arguments: ["title": .string("Pay rent"), "due_date": .string("tomorrow")]
            )
            Issue.record("due_date should have been refused")
        } catch let MacBridgeError.unknownArguments(tool, names, suggestions, accepted) {
            #expect(tool == "reminders_create_reminder")
            #expect(names == ["due_date"])
            #expect(suggestions["due_date"] == "due")
            #expect(accepted.contains("due"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Suggestions find the intended name", arguments: [
        ("calendar_search_events", "calendar_id", "calendars"),
        ("calendar_search_events", "start", "start_date"),
        ("calendar_create_event", "titel", "title"),
        ("reminders_search_reminders", "querry", "query"),
    ])
    func suggestions(tool: String, wrong: String, intended: String) throws {
        let advertised = Set(
            ToolRegistry.definitions().first { $0.name == tool }?
                .inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? []
        )
        #expect(ToolRegistry.closestName(to: wrong, among: advertised) == intended)
    }

    @Test("Advertised names, undocumented aliases and no arguments all pass")
    func acceptedNamesPass() throws {
        try ToolRegistry.checkArgumentNames(tool: "calendar_list_calendars", arguments: nil)
        try ToolRegistry.checkArgumentNames(tool: "calendar_list_calendars", arguments: [:])
        try ToolRegistry.checkArgumentNames(
            tool: "calendar_cancel_event",
            arguments: ["event_id": .string("x"), "occurrence_date": .string("today"), "span": .string("this_event")]
        )
        try ToolRegistry.checkArgumentNames(tool: "calendar_cancel_event", arguments: ["id": .string("x")])
        try ToolRegistry.checkArgumentNames(tool: "reminders_search_reminders", arguments: ["lists": .string("Home")])
        try ToolRegistry.checkArgumentNames(
            tool: "reminders_update_reminder",
            arguments: ["reminder_id": .string("x"), "alarm": .bool(false)]
        )
    }

    @Test("Every hidden alias belongs to a real tool")
    func aliasesNameRealTools() {
        // A renamed tool would otherwise leave its aliases silently dead.
        #expect(ToolRegistry.aliasedToolNames.isSubset(of: Set(ToolRegistry.toolNames)))
        #expect(throws: MacBridgeError.self) {
            try ToolRegistry.checkArgumentNames(tool: "calendar_create_event", arguments: ["id": .string("x")])
        }
    }
}

/// Which bridge requests may be sent twice after a dropped connection.
@Suite("Bridge retry safety")
struct BridgeRetryTests {

    @Test("Reads and inventory may repeat; writes never do")
    func onlyReadsRepeat() {
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .list)))
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .ping)))
        #expect(BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: "calendar_search_events")))
        for tool in ToolRegistry.definitions() where tool.annotations.readOnlyHint != true {
            #expect(!BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: tool.name)),
                    "\(tool.name) changes data and must not be resent")
        }
        #expect(!BridgeClient.isSafeToRepeat(BridgeRequest(id: 1, op: .call, name: nil)))
    }
}

/// What may be persisted: the log file and the unified log hold no calendar data.
@Suite("Log redaction")
struct LogRedactionTests {

    @Test("Logged errors keep the argument name but drop the value")
    func errorsAreRedacted() {
        let secret = "Dentist with Dr Smith"
        let cases: [MacBridgeError] = [
            .invalidArgument(name: "start", reason: "could not read '\(secret)' as a date"),
            .notFound(kind: "reminder list", identifier: secret),
            .notWritable(kind: "calendar", identifier: secret),
        ]
        for error in cases {
            #expect(!error.logDescription.contains(secret), "\(error) leaked into the log")
            #expect(error.errorDescription?.contains(secret) == true, "the model still gets the detail")
        }
        #expect(MacBridgeError.invalidArgument(name: "start", reason: "x").logDescription.contains("'start'"))
    }

    @Test("Write summaries leave titles out when asked to")
    func summariesDropTitles() {
        let result: Value = .object(["created": .bool(true), "event": .object(["title": .string("Dentist")])])
        #expect(ActivitySummary.summarize(result) == "created \u{201C}Dentist\u{201D}")
        #expect(ActivitySummary.summarize(result, includeTitles: false) == "created")
    }
}

