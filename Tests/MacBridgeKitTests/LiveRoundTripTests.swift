//
//  LiveRoundTripTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Opt-in tests against real Calendar and Reminders data.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// True when live tests are requested *and* the domain is actually granted, so a
/// missing permission skips the suite rather than failing it.
func liveTestsEnabled(_ domain: EventKitDomain) -> Bool {
    guard ProcessInfo.processInfo.environment["MACBRIDGE_LIVE"] != nil else { return false }
    return EventKitAuthorization.hasFullAccess(EventKitAuthorization.status(for: domain))
}

/// Live round-trip against real EventKit data.
///
/// Opt-in, because these tests need Calendar and Reminders permission and they
/// write to the user's actual Reminders database. `make test` leaves them off;
/// `make verify` sets MACBRIDGE_LIVE=1 to run them.
///
/// Everything happens inside a list the suite creates and deletes, so the user's
/// own reminders are never touched. `.serialized` because every test here shares
/// that one list.
@Suite(
    "Live Reminders round-trip",
    .enabled(if: liveTestsEnabled(.reminders),
             "set MACBRIDGE_LIVE=1 and grant Reminders access to run"),
    .serialized
)
struct LiveRoundTripTests {

    static let listName = "MacBridge Test"

    /// Create the scratch list, run `body`, then delete the list whatever happens.
    private func withScratchList(
        _ body: (RemindersService, String) async throws -> Void
    ) async throws {
        let service = RemindersService()

        // A leftover list from an aborted run would make the create fail, so clear
        // it first rather than depending on the previous run having tidied up.
        _ = try? await service.deleteList(Arguments(["list": .string(Self.listName)]))

        let created = try await service.createList(Arguments(["title": .string(Self.listName)]))
        #expect(created.objectValue?["created"]?.boolValue == true)

        do {
            try await body(service, Self.listName)
        } catch {
            _ = try? await service.deleteList(Arguments(["list": .string(Self.listName)]))
            throw error
        }

        let deleted = try await service.deleteList(Arguments(["list": .string(Self.listName)]))
        #expect(deleted.objectValue?["deleted"]?.boolValue == true)
    }

    @Test("A reminder survives create, read, update, complete, reopen and delete")
    func fullLifecycle() async throws {
        try await withScratchList { service, list in
            let due = DateParsing.dateOnly.string(
                from: Calendar.current.date(byAdding: .day, value: 3, to: Date())!
            )

            // Create, with every optional field set.
            let created = try await service.createReminder(Arguments([
                "title": .string("Round-trip probe"),
                "list": .string(list),
                "due": .string("\(due)T14:30:00"),
                "notes": .string("written by the live test suite"),
                "priority": .string("high"),
            ]))
            let reminder = try #require(created.objectValue?["reminder"]?.objectValue)
            let id = try #require(reminder["id"]?.stringValue)

            #expect(reminder["list"]?.stringValue == list)
            #expect(reminder["priority"]?.stringValue == "high")
            #expect(reminder["due_has_time"]?.boolValue == true, "a due time must survive as timed")
            #expect(reminder["completed"]?.boolValue == false)

            // A date-only due must stay all-day rather than acquiring midnight.
            let allDay = try await service.createReminder(Arguments([
                "title": .string("All-day probe"), "list": .string(list), "due": .string(due),
            ]))
            let allDayFields = try #require(allDay.objectValue?["reminder"]?.objectValue)
            #expect(allDayFields["due_has_time"]?.boolValue == false)
            #expect(allDayFields["due"]?.stringValue == due)

            // Read back: by list, by query, by id.
            let all = try await service.searchReminders(Arguments(["list": .string(list)]))
            #expect(all.objectValue?["count"]?.intValue == 2)

            let byQuery = try await service.searchReminders(
                Arguments(["list": .string(list), "query": .string("round-trip")])
            )
            #expect(byQuery.objectValue?["count"]?.intValue == 1, "query is case-insensitive")

            let byID = try await service.searchReminders(Arguments(["reminder_id": .string(id)]))
            let found = try #require(byID.objectValue?["reminders"]?.arrayValue?.first?.objectValue)
            #expect(found["notes"]?.stringValue == "written by the live test suite")

            // Update, including clearing a field with an empty string.
            let updated = try await service.updateReminder(Arguments([
                "reminder_id": .string(id),
                "title": .string("Round-trip probe (edited)"),
                "priority": .string("low"),
                "notes": .string(""),
            ]))
            let updatedFields = try #require(updated.objectValue?["reminder"]?.objectValue)
            #expect(updatedFields["title"]?.stringValue == "Round-trip probe (edited)")
            #expect(updatedFields["priority"]?.stringValue == "low")
            #expect(updatedFields["notes"] == nil, "an empty string clears the notes")

            // Clearing the due date must remove it entirely, not zero it.
            let cleared = try await service.updateReminder(
                Arguments(["reminder_id": .string(id), "due": .string("")])
            )
            #expect(cleared.objectValue?["reminder"]?.objectValue?["due"] == nil)

            // Complete, and confirm it drops out of the default read.
            let completed = try await service.completeReminder(Arguments(["reminder_id": .string(id)]))
            #expect(completed.objectValue?["completed"]?.boolValue == true)
            #expect(completed.objectValue?["changed"]?.boolValue == true)
            #expect(completed.objectValue?["reminder"]?.objectValue?["completed_at"] != nil)

            let visible = try await service.searchReminders(Arguments(["list": .string(list)]))
            #expect(visible.objectValue?["count"]?.intValue == 1, "completed items are hidden by default")

            let including = try await service.searchReminders(
                Arguments(["list": .string(list), "include_completed": .bool(true)])
            )
            #expect(including.objectValue?["count"]?.intValue == 2)

            // Reopening must clear the completion date, not leave it stale.
            let reopened = try await service.completeReminder(
                Arguments(["reminder_id": .string(id), "completed": .bool(false)])
            )
            #expect(reopened.objectValue?["completed"]?.boolValue == false)
            #expect(reopened.objectValue?["reminder"]?.objectValue?["completed_at"] == nil)

            // Delete one, leaving the other for the list teardown to report.
            let deleted = try await service.deleteReminder(Arguments(["reminder_id": .string(id)]))
            #expect(deleted.objectValue?["deleted"]?.boolValue == true)
        }
    }

    @Test("Renaming a list keeps its reminders")
    func renameList() async throws {
        let service = RemindersService()
        let original = "MacBridge Rename Test"
        let renamed = original + " 2"

        _ = try? await service.deleteList(Arguments(["list": .string(original)]))
        _ = try? await service.deleteList(Arguments(["list": .string(renamed)]))

        _ = try await service.createList(Arguments(["title": .string(original)]))

        do {
            _ = try await service.createReminder(
                Arguments(["title": .string("Survivor"), "list": .string(original)])
            )

            let result = try await service.updateList(
                Arguments(["list": .string(original), "title": .string(renamed)])
            )
            #expect(result.objectValue?["renamed_from"]?.stringValue == original)

            let after = try await service.searchReminders(Arguments(["list": .string(renamed)]))
            #expect(after.objectValue?["count"]?.intValue == 1, "reminders follow the rename")

            let removed = try await service.deleteList(Arguments(["list": .string(renamed)]))
            #expect(removed.objectValue?["reminders_deleted"]?.intValue == 1,
                    "the destroyed reminder count is reported")
        } catch {
            _ = try? await service.deleteList(Arguments(["list": .string(renamed)]))
            _ = try? await service.deleteList(Arguments(["list": .string(original)]))
            throw error
        }
    }

    @Test("Bad input is refused with a message that names the problem")
    func errorMessages() async throws {
        let service = RemindersService()

        await #expect(throws: MacBridgeError.self) {
            _ = try await service.updateReminder(
                Arguments(["reminder_id": .string("not-a-real-id"), "title": .string("x")])
            )
        }

        do {
            _ = try await service.createReminder(Arguments(["list": .string(Self.listName)]))
            Issue.record("a reminder with no title should be refused")
        } catch let error as MacBridgeError {
            #expect(error == .missingArgument("title"))
        }
    }

    @Test("Listing reminder lists reports a default")
    func enumeration() async throws {
        let reminders = try await RemindersService().listLists(Arguments([:]))
        #expect((reminders.objectValue?["count"]?.intValue ?? 0) > 0)
        #expect(reminders.objectValue?["default"] != nil)
    }

    @Test("A reminder due today with no time is not yet reported overdue")
    func overdueAgreesWithTheFilter() async throws {
        try await withScratchList { service, list in
            let today = DateParsing.dateOnly.string(from: Date())

            let created = try await service.createReminder(Arguments([
                "title": .string("Due today, no time"),
                "list": .string(list),
                "due": .string(today),
            ]))
            let fields = try #require(created.objectValue?["reminder"]?.objectValue)

            // The payload flag and the overdue filter must agree: a date-only due is
            // not late until the day is over. These disagreed, so a model reading
            // both got contradictory answers about the same reminder.
            let flaggedOverdue = fields["overdue"]?.boolValue ?? false

            let filtered = try await service.searchReminders(
                Arguments(["list": .string(list), "overdue": .bool(true)])
            )
            let matchedFilter = (filtered.objectValue?["count"]?.intValue ?? 0) > 0

            #expect(flaggedOverdue == matchedFilter,
                    "the overdue flag and the overdue filter must agree")
            #expect(flaggedOverdue == false, "not overdue until the day is over")
        }
    }
}

/// Calendar is granted separately from Reminders, so it gets its own gate.
@Suite(
    "Live Calendar round-trip",
    .enabled(if: liveTestsEnabled(.calendar),
             "set MACBRIDGE_LIVE=1 and grant Calendar access to run"),
    .serialized
)
struct LiveCalendarTests {

    @Test("Listing calendars reports a default and excludes Scheduled Reminders")
    func listCalendars() async throws {
        let result = try await CalendarService().listCalendars()
        let calendars = try #require(result.objectValue?["calendars"]?.arrayValue)
        #expect(!calendars.isEmpty)

        let titles = calendars.compactMap { $0.objectValue?["title"]?.stringValue }
        // A guard, not a filter test: EventKit itself omits Calendar.app's virtual
        // view of dated reminders, so they are never double-reported as events.
        #expect(!titles.contains("Scheduled Reminders"),
                "the virtual reminders calendar must not appear as an event calendar")
    }

    @Test("The cached and uncached responses have the same shape")
    func cacheShapeIsStable() async throws {
        // Two calls inside the 30s TTL: the second is served from cache, and used to
        // drop the "default" key, so a model saw the field vanish.
        let service = CalendarService()
        let first = try await service.listCalendars()
        let second = try await service.listCalendars()

        #expect(first.objectValue?.keys.sorted() == second.objectValue?.keys.sorted())
        #expect(second.objectValue?["default"] != nil)
    }

    @Test("A date-only range creates an all-day event, not a midnight-to-midnight one")
    func allDayRange() async throws {
        let service = CalendarService()
        let calendars = try await service.listCalendars()
        let writable = calendars.objectValue?["calendars"]?.arrayValue?
            .first { $0.objectValue?["writable"]?.boolValue == true }
        let calendarName = try #require(writable?.objectValue?["title"]?.stringValue)

        let start = DateParsing.dateOnly.string(
            from: Calendar.current.date(byAdding: .day, value: 400, to: Date())!
        )
        let end = DateParsing.dateOnly.string(
            from: Calendar.current.date(byAdding: .day, value: 402, to: Date())!
        )

        let created = try await service.createEvent(Arguments([
            "title": .string("MacBridge all-day probe"),
            "calendar": .string(calendarName),
            "start": .string(start),
            "end": .string(end),
        ]))
        let event = try #require(created.objectValue?["event"]?.objectValue)
        let id = try #require(event["id"]?.stringValue)

        defer {
            Task { _ = try? await service.cancelEvent(Arguments(["event_id": .string(id)])) }
        }

        #expect(event["all_day"]?.boolValue == true,
                "two date-only endpoints mean an all-day event")
        #expect(event["start"]?.stringValue == start, "an all-day start formats as a bare date")
    }

    @Test("Free/busy search returns slots inside the requested working hours")
    func availability() async throws {
        let result = try await CalendarService().findAvailableTimes(Arguments([
            "duration_minutes": .int(30),
            "start_date": .string("today"),
            "end_date": .string("+5d"),
            "day_start_hour": .int(9),
            "day_end_hour": .int(17),
        ]))

        let slots = try #require(result.objectValue?["slots"]?.arrayValue)
        #expect(result.objectValue?["requested_duration_minutes"]?.intValue == 30)

        for slot in slots {
            let fields = try #require(slot.objectValue)
            let start = try #require(fields["start"]?.stringValue)
            let parsed = try #require(DateParsing.parse(start))
            let hour = Calendar.current.component(.hour, from: parsed.date)
            #expect(hour >= 9 && hour < 17, "slot at \(start) falls outside working hours")
            #expect((fields["duration_minutes"]?.intValue ?? 0) >= 30)
        }
    }
}
