//
//  ResourceCatalogTests.swift
//  MacBridgeKitTests · MacBridge
//
//  The MCP resources: listing, URIs, and the tool calls each read makes.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import Testing

@testable import MacBridgeKit

@Suite("Resource catalog")
struct ResourceCatalogTests {

    /// Records the calls a read makes and answers each with a stand-in result.
    final class FakeTools: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(name: String, arguments: [String: Value])] = []
        var calls: [(name: String, arguments: [String: Value])] { lock.withLock { recorded } }

        var call: ResourceCatalog.CallTool {
            { name, arguments in
                self.lock.withLock { self.recorded.append((name, arguments ?? [:])) }
                return .object(["tool": .string(name)])
            }
        }
    }

    /// 2026-11-21 10:00 in UTC, read with a UTC calendar.
    let now = Date(timeIntervalSince1970: 1_795_255_200)
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func json(_ content: Resource.Content) throws -> [String: Value] {
        #expect(content.mimeType == ResourceCatalog.mimeType)
        let data = Data((content.text ?? "").utf8)
        return try JSONDecoder().decode(Value.self, from: data).objectValue ?? [:]
    }

    @Test("Every tool a read calls is a real read-only tool")
    func callsReadOnlyTools() async throws {
        let tools = FakeTools()
        for uri in ResourceCatalog.fixed.map(\.uri) + [ResourceCatalog.listURI(id: "L1")] {
            _ = try await ResourceCatalog.read(uri, call: tools.call, now: now, calendar: utc)
        }
        let readOnly = Set(ToolRegistry.definitions().filter { $0.annotations.readOnlyHint == true }.map(\.name))
        #expect(!tools.calls.isEmpty)
        for call in tools.calls {
            #expect(readOnly.contains(call.name), "'\(call.name)' isn't a read-only tool")
            // The tools refuse unknown arguments, so every one passed must exist.
            let schema = ToolRegistry.definitions().first { $0.name == call.name }?.inputSchema
            let properties = Set(schema?.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
            #expect(Set(call.arguments.keys).isSubset(of: properties), "'\(call.name)' arguments")
            // And integers within the schema's bounds, which the tools enforce too.
            let schemaProperties = schema?.objectValue?["properties"]?.objectValue ?? [:]
            for (key, value) in call.arguments {
                guard case .int(let number) = value, let spec = schemaProperties[key]?.objectValue else { continue }
                if case .int(let maximum)? = spec["maximum"] { #expect(number <= maximum, "'\(call.name)'.\(key)") }
                if case .int(let minimum)? = spec["minimum"] { #expect(number >= minimum, "'\(call.name)'.\(key)") }
            }
        }
    }

    @Test("Today covers one day, with its reminders and the overdue ones")
    func today() async throws {
        let tools = FakeTools()
        let content = try await ResourceCatalog.read("macbridge://agenda/today", call: tools.call, now: now, calendar: utc)
        let object = try json(content)
        #expect(object["date"] == .string("2026-11-21"))
        #expect(object.keys.sorted() == ["date", "events", "overdue", "reminders_due"])
        let events = try #require(tools.calls.first { $0.name == "calendar_search_events" })
        #expect(events.arguments["start_date"] == .string("2026-11-21"))
        #expect(events.arguments["end_date"] == .string("2026-11-21"))
        #expect(tools.calls.contains { $0.arguments["overdue"] == .bool(true) })
    }

    @Test("The week is seven days counting today, the same span for events and reminders")
    func week() async throws {
        let tools = FakeTools()
        let object = try json(try await ResourceCatalog.read("macbridge://agenda/week", call: tools.call, now: now, calendar: utc))
        #expect(object["from"] == .string("2026-11-21"))
        #expect(object["through"] == .string("2026-11-27"))
        let events = try #require(tools.calls.first { $0.name == "calendar_search_events" })
        let reminders = try #require(tools.calls.first { $0.name == "reminders_search_reminders" })
        #expect(events.arguments["end_date"] == .string("2026-11-27"))
        #expect(reminders.arguments["due_after"] == .string("2026-11-21"))
        #expect(reminders.arguments["due_before"] == .string("2026-11-27"))
    }

    @Test("A list's resource searches that list by id")
    func perList() async throws {
        let tools = FakeTools()
        let uri = ResourceCatalog.listURI(id: "ABC/12 3")
        #expect(!uri.dropFirst(ResourceCatalog.listPrefix.count).contains("/"))
        _ = try await ResourceCatalog.read(uri, call: tools.call, now: now, calendar: utc)
        #expect(tools.calls.first?.arguments["list"] == .array([.string("ABC/12 3")]))
    }

    @Test("Listing reads nothing, so connecting never asks for Reminders access")
    func listingReadsNothing() {
        #expect(ResourceCatalog.resources == ResourceCatalog.fixed)
        #expect(ResourceCatalog.templates.map(\.uriTemplate) == ["macbridge://reminders/list/{list_id}"])
        #expect(Set(ResourceCatalog.fixed.map(\.uri)).count == ResourceCatalog.fixed.count)
    }

    @Test("Dates are Gregorian whatever calendar the user has chosen",
          arguments: [Calendar.Identifier.buddhist, .japanese, .hebrew, .islamicUmmAlQura])
    func gregorianDays(identifier: Calendar.Identifier) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(ResourceCatalog.day(now, calendar: calendar) == "2026-11-21")
    }

    @Test("The day is the one in the calendar's time zone")
    func timeZoneNearMidnight() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-11-21 20:00 UTC is already the 22nd in Tokyo.
        #expect(ResourceCatalog.day(now.addingTimeInterval(10 * 3600), calendar: tokyo) == "2026-11-22")
    }

    @Test("Today lists a reminder due earlier today once, as due today")
    func todayDeduplicates() {
        let due: Value = .object(["reminders": .array([.object(["id": .string("A")])]), "count": .int(1)])
        let overdue: Value = .object(["reminders": .array([
            .object(["id": .string("A")]), .object(["id": .string("B")]),
        ]), "count": .int(2)])
        let kept = ResourceCatalog.dropping(overdue, alsoIn: due).objectValue
        #expect(kept?["reminders"] == .array([.object(["id": .string("B")])]))
        #expect(kept?["count"] == .int(1))
    }

    @Test("List ids round-trip through the URI", arguments: ["ABC/12 3", "a%2Fb", "100%", "x+y z", "é/ü?#"])
    func listIDRoundTrip(id: String) {
        let uri = ResourceCatalog.listURI(id: id)
        #expect(!uri.dropFirst(ResourceCatalog.listPrefix.count).contains("/"))
        #expect(ResourceCatalog.listID(from: uri) == id)
    }

    @Test("Unknown URIs are refused", arguments: [
        "macbridge://agenda/tomorrow", "macbridge://reminders/list/", "macbridge://reminders/list/a/b",
        "file:///etc/passwd", "",
    ])
    func unknown(uri: String) async {
        await #expect(throws: ResourceCatalog.ResourceError.unknownResource(uri)) {
            try await ResourceCatalog.read(uri, call: FakeTools().call)
        }
    }
}
