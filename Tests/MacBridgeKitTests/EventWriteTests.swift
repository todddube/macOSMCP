//
//  EventWriteTests.swift
//  MacBridgeKitTests · MacBridge
//
//  Several alerts and per-event time zones, applied to unsaved events.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP
import Testing

@testable import MacBridgeKit

/// Events here are built on a store but never saved, so nothing touches data.
@Suite("Event alerts")
struct EventAlarmTests {

    private let store = EKEventStore()

    /// The `invalidArgument` a call throws, as (name, reason).
    private func refusal(_ raw: [String: Value]) -> (name: String, reason: String)? {
        do {
            _ = try CalendarService.requestedAlarmMinutes(Arguments(raw))
        } catch MacBridgeError.invalidArgument(let name, let reason) {
            return (name, reason)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        return nil
    }

    /// Minutes before the start of each relative alert, sorted.
    private func relativeMinutes(_ event: EKEvent) -> [Int] {
        (event.alarms ?? [])
            .filter { $0.absoluteDate == nil && $0.structuredLocation == nil }
            .map { Int(-$0.relativeOffset / 60) }
            .sorted()
    }

    @Test("Neither argument means the alerts are left alone")
    func untouched() throws {
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["title": "x"])) == nil)
    }

    @Test("alarm_minutes_before still asks for one alert, and null or \"\" for none")
    func single() throws {
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarm_minutes_before": 15])) == [15])
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarm_minutes_before": .null])) == [])
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarm_minutes_before": ""])) == [])
        #expect(refusal(["alarm_minutes_before": -5])?.name == "alarm_minutes_before")
    }

    @Test("alarms_minutes_before takes several, without repeats, in order")
    func several() throws {
        let minutes = try CalendarService.requestedAlarmMinutes(Arguments(["alarms_minutes_before": [60, 10, 0, 10]]))
        #expect(minutes == [60, 10, 0])
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarms_minutes_before": 30])) == [30])
    }

    @Test("Null, \"\" or an empty list asks for none", arguments: [Value.null, .array([]), .string("")])
    func none(empty: Value) throws {
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarms_minutes_before": empty])) == [])
    }

    @Test("On create, null or \"\" counts as not given; only [] asks for no alerts")
    func createNulls() throws {
        func create(_ raw: [String: Value]) throws -> [Int]? {
            try CalendarService.requestedAlarmMinutes(Arguments(raw), creating: true)
        }
        #expect(try create(["alarm_minutes_before": .null]) == nil)
        #expect(try create(["alarm_minutes_before": ""]) == nil)
        #expect(try create(["alarms_minutes_before": .null]) == nil)
        #expect(try create(["alarms_minutes_before": []]) == [])
        #expect(try create(["alarm_minutes_before": .null, "alarms_minutes_before": [10, 60]]) == [10, 60])
        #expect(throws: MacBridgeError.self) { try create(["alarm_minutes_before": 5, "alarms_minutes_before": [10]]) }
    }

    @Test("Both arguments together are refused")
    func both() throws {
        let refused = try #require(refusal(["alarm_minutes_before": 10, "alarms_minutes_before": [10, 60]]))
        #expect(refused.name == "alarms_minutes_before")
        #expect(refused.reason.contains("alarm_minutes_before"))
        // Even when one of them is null: which was meant is unclear.
        #expect(refusal(["alarm_minutes_before": .null, "alarms_minutes_before": [10]]) != nil)
    }

    @Test("More than five alerts are refused")
    func tooMany() throws {
        let refused = try #require(refusal(["alarms_minutes_before": [1, 2, 3, 4, 5, 6]]))
        #expect(refused.reason.contains("5"))
        #expect(try CalendarService.requestedAlarmMinutes(Arguments(["alarms_minutes_before": [1, 2, 3, 4, 5, 5]]))
            == [1, 2, 3, 4, 5])
    }

    @Test("Negative, huge or non-numeric minutes are refused", arguments: [
        Value.array([-1]), .array([10, 1_000_000]), .array(["soon"]), .array([.bool(true)]),
    ])
    func badMinutes(value: Value) {
        #expect(refusal(["alarms_minutes_before": value])?.name == "alarms_minutes_before")
    }

    @Test("Setting alerts on a new event adds each one")
    func setOnCreate() {
        let event = EKEvent(eventStore: store)
        CalendarService.replaceRelativeAlarms(on: event, minutesBefore: [10, 60])
        #expect(relativeMinutes(event) == [10, 60])
    }

    @Test("Replacing alerts keeps those at a fixed time or place")
    func replaceKeepsAbsolute() throws {
        let event = EKEvent(eventStore: store)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        event.addAlarm(EKAlarm(relativeOffset: -900))
        event.addAlarm(EKAlarm(absoluteDate: at))
        let place = EKAlarm()
        place.structuredLocation = EKStructuredLocation(title: "Home")
        place.proximity = .enter
        event.addAlarm(place)

        CalendarService.replaceRelativeAlarms(on: event, minutesBefore: [5, 30, 120])
        #expect(relativeMinutes(event) == [5, 30, 120])
        #expect(event.alarms?.contains { $0.absoluteDate == at } == true)
        #expect(event.alarms?.contains { $0.structuredLocation?.title == "Home" } == true)

        CalendarService.replaceRelativeAlarms(on: event, minutesBefore: [])
        #expect(relativeMinutes(event).isEmpty)
        #expect(event.alarms?.count == 2, "the fixed-time and place alerts stay")
    }

    @Test("After saving adds a default alert, only the ones asked for are kept")
    func keepOnlyRequested() {
        let event = EKEvent(eventStore: store)
        CalendarService.replaceRelativeAlarms(on: event, minutesBefore: [10, 60])
        // What Calendar's "Default alert" setting adds on save.
        event.addAlarm(EKAlarm(relativeOffset: -900))
        event.addAlarm(EKAlarm(relativeOffset: -600))
        event.addAlarm(EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_800_000_000)))

        #expect(CalendarService.keepOnlyAlarms(minutesBefore: [10, 60], on: event))
        #expect(relativeMinutes(event) == [10, 60])
        #expect(event.alarms?.count == 3)
        #expect(!CalendarService.keepOnlyAlarms(minutesBefore: [10, 60], on: event), "nothing left to remove")

        #expect(CalendarService.keepOnlyAlarms(minutesBefore: [], on: event))
        #expect(relativeMinutes(event).isEmpty)
    }
}

/// `time_zone` on create and update, through the store-free helpers the tools use.
@Suite("Event time zones")
struct EventTimeZoneTests {

    private let store = EKEventStore()
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func instant(_ text: String) throws -> Date {
        try #require(DateParsing.parse(text)).date
    }

    /// A new event with the create tool's times applied.
    private func created(_ raw: [String: Value]) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        try CalendarService.setTimes(Arguments(raw), on: event)
        return event
    }

    /// A timed event 09:00–10:00 on 1 July 2026 in Los Angeles.
    private func laMeeting() throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.timeZone = losAngeles
        event.startDate = try instant("2026-07-01T09:00:00-07:00")
        event.endDate = try instant("2026-07-01T10:00:00-07:00")
        return event
    }

    // MARK: Create

    @Test("A floating start and end are wall-clock times in the event's zone")
    func createFloating() throws {
        let event = try created([
            "start": "2026-07-01T09:00:00", "end": "2026-07-01T10:30", "time_zone": "America/New_York",
        ])
        #expect(event.timeZone?.identifier == "America/New_York")
        #expect(event.isAllDay == false)
        #expect(event.startDate == (try instant("2026-07-01T13:00:00Z")))
        #expect(event.endDate == (try instant("2026-07-01T14:30:00Z")))
    }

    @Test("An explicit offset is honoured, and the zone still set")
    func createExplicitOffset() throws {
        let event = try created(["start": "2026-07-01T09:00:00Z", "time_zone": "Asia/Tokyo"])
        #expect(event.timeZone?.identifier == "Asia/Tokyo")
        #expect(event.startDate == (try instant("2026-07-01T09:00:00Z")))
        #expect(event.endDate == event.startDate.addingTimeInterval(3600))
    }

    @Test("Duration still works with a zone")
    func createDuration() throws {
        let event = try created(["start": "2026-07-01T09:00", "duration_minutes": 45, "time_zone": "Asia/Tokyo"])
        #expect(event.startDate == (try instant("2026-07-01T00:00:00Z")))
        #expect(event.endDate == event.startDate.addingTimeInterval(45 * 60))
    }

    @Test("Relative values stay relative to now")
    func createRelative() throws {
        let before = Date()
        let event = try created(["start": "+2h", "time_zone": "Asia/Tokyo"])
        let start = try #require(event.startDate)
        #expect(start.timeIntervalSince(before) > 7190 && start.timeIntervalSince(before) < 7300)
        #expect(event.timeZone?.identifier == "Asia/Tokyo")
    }

    @Test("An all-day event ignores the zone and stays floating")
    func createAllDay() throws {
        let event = try created(["start": "2026-07-01", "end": "2026-07-03", "time_zone": "Asia/Tokyo"])
        #expect(event.isAllDay)
        #expect(event.timeZone == nil)
        #expect(event.startDate == (try instant("2026-07-01")))
        // EventKit stores an all-day end as the last second of its day.
        #expect(Calendar.current.isDate(try #require(event.endDate), inSameDayAs: try instant("2026-07-03")))

        // A timed start made all-day by the flag keeps its local day, not Tokyo's.
        let forced = try created(["start": "2026-07-01T23:00:00", "all_day": true, "time_zone": "Pacific/Kiritimati"])
        #expect(forced.timeZone == nil)
        #expect(forced.startDate == (try instant("2026-07-01")))
    }

    @Test("A null or blank zone on create means none, like other optional fields")
    func createNullZone() throws {
        for value: Value in [.null, ""] {
            let event = try created(["start": "2026-07-01T09:00:00", "time_zone": value])
            #expect(event.startDate == (try instant("2026-07-01T09:00:00")))
        }
    }

    @Test("Without a zone, create reads local time as before")
    func createWithoutZone() throws {
        let event = try created(["start": "2026-07-01T09:00:00"])
        #expect(event.startDate == (try instant("2026-07-01T09:00:00")))
    }

    @Test("An unknown zone is refused before anything is set")
    func createUnknownZone() {
        do {
            _ = try created(["start": "2026-07-01T09:00:00", "time_zone": "Eastern"])
            Issue.record("expected a refusal")
        } catch MacBridgeError.invalidArgument(let name, let reason) {
            #expect(name == "time_zone")
            #expect(reason.contains("IANA"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: Update

    @Test("time_zone alone keeps the wall-clock times: 9:00 LA becomes 9:00 New York")
    func updateReanchors() throws {
        let event = try laMeeting()
        try CalendarService.changeTimes(Arguments(["time_zone": "America/New_York"]), on: event, timeZone: newYork)
        #expect(event.timeZone?.identifier == "America/New_York")
        #expect(event.startDate == (try instant("2026-07-01T09:00:00-04:00")))
        #expect(event.endDate == (try instant("2026-07-01T10:00:00-04:00")))
    }

    @Test("A new start with a zone is read in the new zone and keeps the length")
    func updateStartInZone() throws {
        let event = try laMeeting()
        try CalendarService.changeTimes(
            Arguments(["time_zone": "Asia/Tokyo", "start": "2026-07-02T15:00"]), on: event, timeZone: tokyo
        )
        #expect(event.timeZone?.identifier == "Asia/Tokyo")
        #expect(event.startDate == (try instant("2026-07-02T15:00:00+09:00")))
        #expect(event.endDate == event.startDate.addingTimeInterval(3600))
    }

    @Test("A new end with a zone moves the start into the zone too")
    func updateEndInZone() throws {
        let event = try laMeeting()
        try CalendarService.changeTimes(
            Arguments(["time_zone": "America/New_York", "end": "2026-07-01T11:00"]), on: event, timeZone: newYork
        )
        #expect(event.startDate == (try instant("2026-07-01T09:00:00-04:00")))
        #expect(event.endDate == (try instant("2026-07-01T11:00:00-04:00")))
    }

    @Test("An explicit offset in an update is honoured as given")
    func updateExplicitOffset() throws {
        let event = try laMeeting()
        try CalendarService.changeTimes(
            Arguments(["time_zone": "America/New_York", "start": "2026-07-01T20:00:00Z"]), on: event, timeZone: newYork
        )
        #expect(event.startDate == (try instant("2026-07-01T20:00:00Z")))
    }

    @Test("Without time_zone an update reads local time and keeps the event's zone")
    func updateWithoutZone() throws {
        let event = try laMeeting()
        try CalendarService.changeTimes(Arguments(["start": "2026-07-02T09:00:00"]), on: event, timeZone: nil)
        #expect(event.timeZone?.identifier == "America/Los_Angeles")
        #expect(event.startDate == (try instant("2026-07-02T09:00:00")))
    }

    @Test("An all-day event ignores time_zone on update")
    func updateAllDay() throws {
        let event = EKEvent(eventStore: store)
        event.isAllDay = true
        event.startDate = try instant("2026-07-01")
        event.endDate = try instant("2026-07-01")
        try CalendarService.changeTimes(Arguments(["time_zone": "Asia/Tokyo"]), on: event, timeZone: tokyo)
        #expect(event.timeZone == nil)
        #expect(event.startDate == (try instant("2026-07-01")))

        try CalendarService.changeTimes(
            Arguments(["time_zone": "Asia/Tokyo", "start": "2026-07-05"]), on: event, timeZone: tokyo
        )
        #expect(event.startDate == (try instant("2026-07-05")))
        #expect(event.timeZone == nil)
    }

    @Test("Moving an all-day event to a zone leaves it alone")
    func moveAllDay() throws {
        let event = EKEvent(eventStore: store)
        event.isAllDay = true
        event.startDate = try instant("2026-07-01")
        CalendarService.moveToTimeZone(event, tokyo)
        #expect(event.timeZone == nil)
        #expect(event.startDate == (try instant("2026-07-01")))
    }

    @Test("The brief result names a zone that isn't the Mac's")
    func mappedZone() throws {
        let event = try laMeeting()
        event.timeZone = TimeZone.current.identifier == "Asia/Tokyo" ? newYork : tokyo
        guard case .object(let mapped) = CalendarMapping.event(event) else {
            Issue.record("expected an object")
            return
        }
        #expect(mapped["time_zone"] == .string(event.timeZone!.identifier))

        event.timeZone = .current
        guard case .object(let local) = CalendarMapping.event(event) else { return }
        #expect(local["time_zone"] == nil)
    }
}
