//
//  CalendarService.swift
//  MacBridgeKit · MacBridge
//
//  Every Calendar operation, backed entirely by EventKit.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP

/// Every Calendar operation, backed entirely by EventKit.
///
/// Each public method implements one `calendar_*` tool: it takes the call's
/// ``Arguments`` and returns a structured `Value`, throwing ``MacBridgeError`` with
/// a message a model can act on.
///
/// An actor because `EKEventStore` is not thread-safe and carries no Sendable
/// annotations. No EventKit object escapes these methods — they are mapped to
/// `Value` before returning — so the actor boundary is the whole safety story.
public actor CalendarService {

    private let store = EKEventStore()
    private let domain = EventKitDomain.calendar

    /// EventKit refuses `predicateForEvents` spans beyond four years.
    private static let maxSpanDays = 365 * 4

    /// Upper bound for any minute-valued argument — one non-leap year. Exists to
    /// keep `minutes * 60` from overflowing, not because anyone needs the range.
    private static let maxMinutes = 60 * 24 * 365

    /// Calendar membership changes rarely, and `tools/list`-style enumerations get
    /// called repeatedly at the start of a conversation.
    /// The default title is cached with the list: returning it on a miss but not on
    /// a hit made two identical calls seconds apart answer with different shapes.
    private var calendarCache: (stamp: Date, calendars: [Value], defaultTitle: Value)?
    private static let cacheTTL: TimeInterval = 30

    /// Creates a service with its own `EKEventStore`; access is requested on first use.
    public init() {}

    private func ensureAccess() async throws {
        try await EventKitAuthorization.ensureAccess(to: domain, store: store)
    }

    // MARK: - calendar_list_calendars

    /// `calendar_list_calendars`: every event calendar, plus the default for new events.
    public func listCalendars() async throws -> Value {
        try await ensureAccess()

        if let cache = calendarCache, Date().timeIntervalSince(cache.stamp) < Self.cacheTTL {
            return .object([
                "calendars": .array(cache.calendars),
                "count": .int(cache.calendars.count),
                "default": cache.defaultTitle,
            ])
        }

        let mapped = CalendarResolution.eventCalendars(in: store).map(CalendarMapping.calendar)
        let defaultTitle = defaultCalendarValue()
        calendarCache = (Date(), mapped, defaultTitle)

        return .object([
            "calendars": .array(mapped),
            "count": .int(mapped.count),
            "default": defaultTitle,
        ])
    }

    private func defaultCalendarValue() -> Value {
        guard let title = store.defaultCalendarForNewEvents?.title else { return .null }
        return .string(title)
    }

    // MARK: - calendar_search_events

    /// `calendar_search_events`: events in a date range, optionally filtered by
    /// calendar, text and all-day, sorted by start and capped at `limit`.
    public func searchEvents(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let now = Date()
        let calendar = Calendar.current

        // Default window: today through +7 days, the span "what's coming up" usually means.
        let startInput = try args.optionalDate("start_date")
        let start = calendar.startOfDay(for: startInput?.date ?? now)

        let endInput = try args.optionalDate("end_date")
        let rawEnd = endInput?.date ?? calendar.date(byAdding: .day, value: 7, to: start) ?? start
        // A date-only end means "through the end of that day", not "at midnight",
        // otherwise "start_date=today end_date=today" would return nothing.
        var end = (endInput?.hasTime ?? false) ? rawEnd : DateParsing.endOfDay(rawEnd)

        guard end > start else {
            throw MacBridgeError.invalidArgument(
                name: "end_date",
                reason: "must be after start_date (\(DateParsing.dateOnly.string(from: start)))"
            )
        }

        var spanWarning: String?
        if let capped = calendar.date(byAdding: .day, value: Self.maxSpanDays, to: start), end > capped {
            end = capped
            spanWarning = "Range narrowed to four years; EventKit cannot query a longer span in one call."
        }

        let names = args.optionalStringArray("calendars") ?? args.optionalStringArray("calendar")
        let calendars = try CalendarResolution.resolveSubset(
            names: names,
            among: CalendarResolution.eventCalendars(in: store),
            kind: "calendar"
        )
        guard !calendars.isEmpty else {
            return .object(["events": .array([]), "count": .int(0),
                            "warning": .string("No calendars available to search.")])
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var events = store.events(matching: predicate)

        if let query = args.optionalString("query") {
            events = events.filter { matches($0, query: query) }
        }
        if try args.bool("include_all_day", default: true) == false {
            events = events.filter { !$0.isAllDay }
        }

        events.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        let limit = try args.int("limit", default: 50, in: 1...500)
        let total = events.count
        let page = Array(events.prefix(limit))

        var out: [String: Value] = [
            "events": .array(page.map(CalendarMapping.event)),
            "count": .int(page.count),
            "start": .string(DateParsing.offsetDateTime.string(from: start)),
            "end": .string(DateParsing.offsetDateTime.string(from: end)),
        ]
        if let query = args.optionalString("query") { out["query"] = .string(query) }
        if names != nil { out["calendars_searched"] = .array(calendars.map { .string($0.title) }) }
        if total > page.count {
            out["truncated"] = .bool(true)
            out["total_matched"] = .int(total)
        }
        if let spanWarning { out["warning"] = .string(spanWarning) }
        return .object(out)
    }

    private func matches(_ event: EKEvent, query: String) -> Bool {
        let needle = query.lowercased()
        if event.title?.lowercased().contains(needle) == true { return true }
        if event.location?.lowercased().contains(needle) == true { return true }
        if event.notes?.lowercased().contains(needle) == true { return true }
        return false
    }

    // MARK: - calendar_create_event

    /// `calendar_create_event`: a new event, all-day when neither endpoint has a time.
    public func createEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let title = try args.requiredString("title")
        let startInput = try args.requiredDate("start")
        let endInput = try args.optionalDate("end")

        // All-day when neither endpoint carries a time. Keying off "no end was
        // given" instead turned {start: 2026-10-01, end: 2026-10-03} into a timed
        // 48-hour event running midnight to midnight, rather than a 3-day all-day
        // event.
        let datesOnly = !startInput.hasTime && !(endInput?.hasTime ?? false)
        let allDay = try args.bool("all_day", default: datesOnly)

        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = allDay
        event.startDate = allDay ? Calendar.current.startOfDay(for: startInput.date) : startInput.date
        event.endDate = try resolveEnd(args, endInput: endInput, start: event.startDate, allDay: allDay)

        let calendars = CalendarResolution.eventCalendars(in: store)
        if let requested = args.optionalString("calendar") {
            let cal = try CalendarResolution.resolve(identifier: requested, among: calendars, kind: "calendar")
            try CalendarResolution.requireWritable(cal, kind: "calendar")
            event.calendar = cal
        } else if let fallback = store.defaultCalendarForNewEvents {
            event.calendar = fallback
        } else {
            guard let firstWritable = calendars.first(where: { $0.allowsContentModifications }) else {
                throw MacBridgeError.notFound(kind: "calendar", identifier: "any writable calendar")
            }
            event.calendar = firstWritable
        }

        if let location = args.optionalString("location") { event.location = location }
        if let notes = args.optionalString("notes") { event.notes = notes }
        if let urlString = args.optionalString("url") { event.url = URL(string: urlString) }
        if let rule = try Recurrence.rule(from: args) { event.addRecurrenceRule(rule) }
        // Bounded: `abs(Int.min)` and `minutes * 60` both trap on extreme input,
        // and a year of lead time is already absurd for an alarm.
        if let minutes = try args.optionalInt("alarm_minutes_before", in: 0...Self.maxMinutes) {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }

        try save(event, span: .futureEvents)
        calendarCache = nil

        return .object([
            "created": .bool(true),
            "event": CalendarMapping.event(event),
        ])
    }

    /// Resolve an event's end from `end` or `duration_minutes`, defaulting to a
    /// one-hour meeting or a single all-day day.
    private func resolveEnd(
        _ args: Arguments,
        endInput: (date: Date, hasTime: Bool)?,
        start: Date,
        allDay: Bool
    ) throws -> Date {
        if let endInput {
            let end = allDay ? Calendar.current.startOfDay(for: endInput.date) : endInput.date
            guard end >= start else {
                throw MacBridgeError.invalidArgument(name: "end", reason: "must not be before 'start'")
            }
            return end
        }
        if let minutes = try args.optionalInt("duration_minutes", in: 1...Self.maxMinutes) {
            return start.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return allDay ? start : start.addingTimeInterval(3600)
    }

    // MARK: - calendar_update_event

    /// `calendar_update_event`: patches an event. Absent keys are left alone; an
    /// explicit null or empty string clears a clearable field.
    public func updateEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let event = try fetchEvent(args)
        let span = try resolveSpan(args)

        // Patch semantics:
        // an absent key leaves the field alone, an explicit null or "" clears it.
        if let title = args.optionalString("title") { event.title = title }

        if let allDay = try args.optionalBool("all_day") { event.isAllDay = allDay }

        let originalDuration = (event.endDate ?? event.startDate ?? Date())
            .timeIntervalSince(event.startDate ?? Date())

        if let startInput = try args.optionalDate("start") {
            event.startDate = event.isAllDay
                ? Calendar.current.startOfDay(for: startInput.date)
                : startInput.date
            // Keep the event valid if only the start moved.
            if !args.contains("end"), let start = event.startDate {
                event.endDate = start.addingTimeInterval(max(originalDuration, 0))
            }
        }
        if let endInput = try args.optionalDate("end") {
            event.endDate = event.isAllDay
                ? Calendar.current.startOfDay(for: endInput.date)
                : endInput.date
        }
        if let start = event.startDate, let end = event.endDate, end < start {
            throw MacBridgeError.invalidArgument(name: "end", reason: "must not be before 'start'")
        }

        if let location = args.clearableString("location") {
            event.location = location.isEmpty ? nil : location
        }
        if let notes = args.clearableString("notes") {
            event.notes = notes.isEmpty ? nil : notes
        }
        if let urlString = args.clearableString("url") {
            event.url = urlString.isEmpty ? nil : URL(string: urlString)
        }

        if args.contains("calendar"), let requested = args.optionalString("calendar") {
            let cal = try CalendarResolution.resolve(
                identifier: requested,
                among: CalendarResolution.eventCalendars(in: store),
                kind: "calendar"
            )
            try CalendarResolution.requireWritable(cal, kind: "calendar")
            event.calendar = cal
        }

        try save(event, span: span)

        return .object([
            "updated": .bool(true),
            "span": .string(span == .thisEvent ? "this_event" : "future_events"),
            "event": CalendarMapping.event(event),
        ])
    }

    // MARK: - calendar_reschedule_event

    /// Move an event, preserving its duration unless a new end is given.
    ///
    /// Separate from `calendar_update_event` because "move my 3pm to 4pm" is the
    /// single most common edit and doing it through a patch tool invites a model
    /// to move the start and leave a stale end behind.
    public func rescheduleEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let event = try fetchEvent(args)
        let span = try resolveSpan(args)

        guard let oldStart = event.startDate else {
            throw MacBridgeError.saveFailed(underlying: "the event has no start date to move")
        }
        let oldEnd = event.endDate ?? oldStart
        let duration = oldEnd.timeIntervalSince(oldStart)

        let newStartInput = try args.requiredDate("new_start")
        let newStart = event.isAllDay
            ? Calendar.current.startOfDay(for: newStartInput.date)
            : newStartInput.date

        let newEnd: Date
        if let explicit = try args.optionalDate("new_end") {
            newEnd = event.isAllDay ? Calendar.current.startOfDay(for: explicit.date) : explicit.date
            guard newEnd >= newStart else {
                throw MacBridgeError.invalidArgument(name: "new_end", reason: "must not be before 'new_start'")
            }
        } else {
            newEnd = newStart.addingTimeInterval(duration)
        }

        event.startDate = newStart
        event.endDate = newEnd
        try save(event, span: span)

        return .object([
            "rescheduled": .bool(true),
            "moved_from": .string(DateParsing.format(oldStart, allDay: event.isAllDay)),
            "span": .string(span == .thisEvent ? "this_event" : "future_events"),
            "event": CalendarMapping.event(event),
        ])
    }

    // MARK: - calendar_cancel_event

    /// `calendar_cancel_event`: deletes an event, or it and its future occurrences.
    /// Irreversible; the result echoes what was removed.
    public func cancelEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let event = try fetchEvent(args)
        let span = try resolveSpan(args)

        // Capture the description before removal; the object is dead afterwards.
        let summary = CalendarMapping.event(event)
        let title = event.title ?? "(no title)"

        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "cancelled": .bool(true),
            "title": .string(title),
            "span": .string(span == .thisEvent ? "this_event" : "future_events"),
            "event": summary,
        ])
    }

    // MARK: - calendar_open_event

    /// `calendar_open_event`: reveals an event in Calendar.app. Works on read-only calendars.
    public func openEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let event = try fetchEvent(args, requireWritable: false)
        guard let identifier = event.eventIdentifier else {
            throw MacBridgeError.notFound(kind: "calendar event", identifier: "identifier missing")
        }
        try Reveal.open(Reveal.calendarEventURL(identifier: identifier))

        return .object([
            "opened": .bool(true),
            "title": .string(event.title ?? "(no title)"),
        ])
    }

    // MARK: - calendar_find_available_times

    /// `calendar_find_available_times`: free slots of at least the requested length
    /// inside daily working hours, treating every non-free, non-cancelled event as busy.
    public func findAvailableTimes(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let calendar = Calendar.current
        let now = Date()

        let startInput = try args.optionalDate("start_date")
        let searchStart = startInput?.date ?? now
        let endInput = try args.optionalDate("end_date")
        let rawEnd = endInput?.date ?? calendar.date(byAdding: .day, value: 7, to: searchStart) ?? searchStart
        let searchEnd = (endInput?.hasTime ?? false) ? rawEnd : DateParsing.endOfDay(rawEnd)

        guard searchEnd > searchStart else {
            throw MacBridgeError.invalidArgument(name: "end_date", reason: "must be after start_date")
        }

        let duration = try args.int("duration_minutes", default: 30, in: 1...(60 * 24))
        let dayStart = try args.int("day_start_hour", default: 9, in: 0...23)
        let dayEnd = try args.int("day_end_hour", default: 17, in: 1...24)
        guard dayStart < dayEnd else {
            throw MacBridgeError.invalidArgument(
                name: "day_start_hour",
                reason: "must be earlier than day_end_hour (\(dayEnd))"
            )
        }

        let names = args.optionalStringArray("calendars") ?? args.optionalStringArray("calendar")
        let calendars = try CalendarResolution.resolveSubset(
            names: names,
            among: CalendarResolution.eventCalendars(in: store),
            kind: "calendar"
        )

        // Busy = anything not explicitly marked free. All-day events block their
        // whole span, which is what a model should assume when offering times.
        var busy: [DateInterval] = []
        if !calendars.isEmpty {
            let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
            for event in store.events(matching: predicate) {
                guard event.availability != .free, event.status != .canceled else { continue }
                guard let s = event.startDate, let e = event.endDate, e > s else { continue }
                busy.append(DateInterval(start: s, end: e))
            }
        }

        let searchRange = DateInterval(start: searchStart, end: searchEnd)
        let windows = FreeBusy.dailyWindows(in: searchRange, startHour: dayStart, endHour: dayEnd)
        let minimum = TimeInterval(duration * 60)

        var slots: [Value] = []
        let limit = try args.int("limit", default: 20, in: 1...200)

        for window in windows {
            for slot in FreeBusy.freeSlots(in: window, busy: busy, minimumDuration: minimum) {
                slots.append(.object([
                    "start": .string(DateParsing.offsetDateTime.string(from: slot.start)),
                    "end": .string(DateParsing.offsetDateTime.string(from: slot.end)),
                    "duration_minutes": .int(Int(slot.duration / 60)),
                ]))
                if slots.count >= limit { break }
            }
            if slots.count >= limit { break }
        }

        return .object([
            "slots": .array(slots),
            "count": .int(slots.count),
            "requested_duration_minutes": .int(duration),
            "searched_from": .string(DateParsing.offsetDateTime.string(from: searchStart)),
            "searched_to": .string(DateParsing.offsetDateTime.string(from: searchEnd)),
            "working_hours": .string(String(format: "%02d:00–%02d:00", dayStart, dayEnd)),
        ])
    }

    // MARK: - Shared helpers

    /// Look up the event named by `event_id`, accepting either of the parameter
    /// spellings a model is likely to reach for.
    /// - Parameter requireWritable: false for read-only operations. `calendar_open_event`
    ///   only reveals an event in Calendar.app, so demanding a writable calendar
    ///   made it fail with a "read-only" error on exactly the calendars people most
    ///   often want to look at — subscribed holiday and shared calendars.
    private func fetchEvent(_ args: Arguments, requireWritable: Bool = true) throws -> EKEvent {
        let identifier = try args.contains("event_id")
            ? args.requiredString("event_id")
            : args.requiredString("id")

        guard let event = store.event(withIdentifier: identifier) else {
            throw MacBridgeError.notFound(kind: "calendar event", identifier: identifier)
        }
        if requireWritable, let cal = event.calendar {
            try CalendarResolution.requireWritable(cal, kind: "calendar")
        }
        return event
    }

    private func resolveSpan(_ args: Arguments) throws -> EKSpan {
        guard let raw = args.optionalString("span") else { return .thisEvent }
        switch raw.lowercased() {
        case "this", "this_event": return .thisEvent
        case "future", "future_events", "all": return .futureEvents
        default:
            throw MacBridgeError.invalidArgument(
                name: "span",
                reason: "expected 'this_event' or 'future_events'"
            )
        }
    }

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }
    }
}
