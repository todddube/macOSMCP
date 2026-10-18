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

        // One event, in full: the counterpart of reminders_search_reminders'
        // reminder_id, and the way to see who is invited to a meeting.
        if args.contains("event_id") {
            let event = try fetchEvent(args, span: nil, requireWritable: false)
            return .object(["events": .array([CalendarMapping.eventDetails(event)]), "count": .int(1)])
        }
        let mapEvent = try args.bool("include_details", default: false)
            ? CalendarMapping.eventDetails
            : CalendarMapping.event

        let now = Date()
        let calendar = Calendar.current

        // Default window: seven days starting with start_date's day — a week, which is
        // what "what's coming up" usually means. (Adding 7 and then extending to the
        // end of that day had made it eight.)
        // A date-only start means "from the beginning of that day"; a timed one is
        // taken as given, so "from 2pm" does not also return the morning.
        let startInput = try args.optionalDate("start_date")
        let start = (startInput?.hasTime ?? false)
            ? startInput!.date
            : calendar.startOfDay(for: startInput?.date ?? now)

        let endInput = try args.optionalDate("end_date")
        let rawEnd = endInput?.date ?? calendar.date(byAdding: .day, value: 6, to: start) ?? start
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
            "events": .array(page.map(mapEvent)),
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
        if let url = try args.optionalURL("url") { event.url = url }
        if let rule = try Recurrence.rule(from: args) { event.addRecurrenceRule(rule) }
        try applyAvailability(args, to: event)
        // Bounded: `abs(Int.min)` and `minutes * 60` both trap on extreme input,
        // and a year of lead time is already absurd for an alarm.
        let alarmMinutes = try args.optionalInt("alarm_minutes_before", in: 0...Self.maxMinutes)
        if let alarmMinutes {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alarmMinutes * 60)))
        }

        try save(event, span: .futureEvents)

        // Saving adds the account's default alert (Calendar's "Default alert"
        // setting), so asking for 10 minutes left two alerts, 10 and 15, and
        // asking for 15 left two at 15. An alert asked for replaces the default.
        // The event already exists by now, so a failure here must not read as a
        // failed create, or the model would try again and make a second one.
        var warning: String?
        if let alarmMinutes, keepOnlyAlarm(minutesBefore: alarmMinutes, on: event) {
            do {
                try save(event, span: .futureEvents)
            } catch {
                // Back to what was stored, so the result shows the alerts it has.
                event.rollback()
                warning = "The event was created, but Calendar's default alert may also be on it."
            }
        }
        calendarCache = nil

        var out: [String: Value] = [
            "created": .bool(true),
            "event": CalendarMapping.event(event),
        ]
        if let warning { out["warning"] = .string(warning) }
        return .object(out)
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

        let span = try resolveSpan(args)
        let changesRepeat = Recurrence.isRequested(in: args)
        if changesRepeat, span == .thisEvent { try requireSeriesSpanForRepeatChange(args) }
        let event = try fetchEvent(args, span: span)
        if changesRepeat, span == .thisEvent, Self.repeats(event) { try refuseRepeatChange(on: event) }
        if span == .allEvents, Self.repeats(event),
           let moved = ["start", "end", "all_day"].first(where: args.contains) {
            throw MacBridgeError.invalidArgument(
                name: moved,
                reason: """
                    changing the time with span 'all_events' would move the series' first occurrence. \
                    Use calendar_reschedule_event with an occurrence_date and span 'future_events'.
                    """
            )
        }

        // Patch semantics:
        // an absent key leaves the field alone, an explicit null or "" clears it.
        if let title = args.optionalString("title") { event.title = title }

        let originalDuration = (event.endDate ?? event.startDate ?? Date())
            .timeIntervalSince(event.startDate ?? Date())

        var becameTimed = false
        if let allDay = try args.optionalBool("all_day"), allDay != event.isAllDay {
            if allDay {
                // Snap to whole days, or the event keeps its old mid-day times and
                // Calendar shows them oddly. The start and end days are kept.
                let calendar = Calendar.current
                event.isAllDay = true
                if let start = event.startDate { event.startDate = calendar.startOfDay(for: start) }
                if let end = event.endDate { event.endDate = calendar.startOfDay(for: end) }
            } else {
                // An all-day event has no time to keep; guessing one (midnight to
                // 23:59:59) made an event nobody asked for.
                guard args.contains("start") else {
                    throw MacBridgeError.invalidArgument(
                        name: "all_day",
                        reason: "making an all-day event timed needs a start time; pass start, and end if it should last other than an hour"
                    )
                }
                event.isAllDay = false
                becameTimed = true
            }
        }

        if let startInput = try args.optionalDate("start") {
            event.startDate = event.isAllDay
                ? Calendar.current.startOfDay(for: startInput.date)
                : startInput.date
            // Keep the event valid if only the start moved. A former all-day
            // event's "duration" is a span of days, so it gets the usual hour.
            if !args.contains("end"), let start = event.startDate {
                event.endDate = start.addingTimeInterval(becameTimed ? 3600 : max(originalDuration, 0))
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
        if let url = try args.clearableURL("url") { event.url = url }

        if args.contains("calendar"), let requested = args.optionalString("calendar") {
            let cal = try CalendarResolution.resolve(
                identifier: requested,
                among: CalendarResolution.eventCalendars(in: store),
                kind: "calendar"
            )
            try CalendarResolution.requireWritable(cal, kind: "calendar")
            event.calendar = cal
        }

        try applyAvailability(args, to: event)
        try applyAlarm(args, to: event)

        // A repeat belongs to the series from this occurrence on, so it is always
        // saved that way; for an event that didn't repeat the span makes no
        // difference.
        var saveSpan = span.ekSpan
        if changesRepeat {
            try applyRepeat(args, to: event, splitsSeries: span == .futureEvents && !isFirstOccurrence(event))
            saveSpan = .futureEvents
        }

        try save(event, span: saveSpan)

        return .object([
            "updated": .bool(true),
            "span": .string(span.rawValue),
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

        let span = try resolveSpan(args)
        let event = try fetchEvent(args, span: span)
        if span == .allEvents, Self.repeats(event) {
            throw MacBridgeError.invalidArgument(
                name: "span",
                reason: """
                    'all_events' would move the series' first occurrence, and every later one with it, \
                    to new_start. Pass the occurrence_date to move from with span 'future_events' instead.
                    """
            )
        }

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
        try save(event, span: span.ekSpan)

        return .object([
            "rescheduled": .bool(true),
            "moved_from": .string(DateParsing.format(oldStart, allDay: event.isAllDay)),
            "span": .string(span.rawValue),
            "event": CalendarMapping.event(event),
        ])
    }

    // MARK: - calendar_cancel_event

    /// `calendar_cancel_event`: deletes an event, or it and its future occurrences.
    /// Irreversible; the result echoes what was removed.
    public func cancelEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let span = try resolveSpan(args)
        let event = try fetchEvent(args, span: span)

        // Capture the description before removal; the object is dead afterwards.
        let summary = CalendarMapping.event(event)
        let title = event.title ?? "(no title)"

        do {
            try store.remove(event, span: span.ekSpan, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "cancelled": .bool(true),
            "title": .string(title),
            "span": .string(span.rawValue),
            "event": summary,
        ])
    }

    /// The event a `calendar_cancel_event` call would remove, in words for the
    /// confirmation prompt; nil when it can't be found (the call itself will then
    /// fail with the reason).
    public func confirmationTarget(_ args: Arguments) async -> String? {
        guard (try? await ensureAccess()) != nil,
              let span = try? resolveSpan(args),
              let event = try? fetchEvent(args, span: span, requireWritable: false)
        else { return nil }

        var text = "the event \u{201C}\(event.title ?? "(no title)")\u{201D}"
        if let start = event.startDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = event.isAllDay ? .none : .short
            text += " on \(formatter.string(from: start))"
        }
        if Self.repeats(event) {
            switch span {
            case .thisEvent: text += " (this occurrence only)"
            case .futureEvents: text += ", and every later occurrence"
            case .allEvents:
                // Calendar keeps a part split off by an earlier "from this one on"
                // change tied to the series, and deleting the series takes it too.
                text += ", and every occurrence of the repeating series, including any later part split off by an earlier repeat change"
            }
        }
        return text
    }

    /// What changing a repeating event's repeat would remove, in words for the
    /// confirmation prompt. `needed` is false when the event doesn't repeat, since
    /// nothing can be lost, and when the call would refuse anyway; it is true with
    /// no target only when Calendar access itself can't be checked.
    ///
    /// Stopping a repeat or changing its rule removes the occurrences that no
    /// longer fit, from the chosen one on, so with Ask before deleting on this is
    /// confirmed like a delete.
    public func repeatChangeTarget(_ args: Arguments) async -> (needed: Bool, target: String?) {
        guard Recurrence.isRequested(in: args) else { return (false, nil) }
        guard (try? await ensureAccess()) != nil else { return (true, nil) }

        // Each check below matches one the call makes itself, which refuses a
        // repeat change on a single occurrence and an event it can't find; asking
        // first would hold the user up for an error. They look at the event the
        // call would write, as the call resolves it, not at whatever the bare id
        // names.
        guard let span = try? resolveSpan(args), span != .thisEvent,
              let event = try? fetchEvent(args, span: span)
        else { return (false, nil) }
        // Making a one-off event repeat loses nothing, and one occurrence moved on
        // its own has no repeat to change, which the call refuses.
        guard event.hasRecurrenceRules else { return (false, nil) }

        let title = "\u{201C}\(event.title ?? "(no title)")\u{201D}"
        var from = ""
        if let start = event.startDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            from = " after \(formatter.string(from: start))"
        }
        // Arguments the call would refuse aren't worth asking about either.
        let change: Recurrence.Change?
        do {
            change = try Recurrence.change(
                from: args,
                existing: event.recurrenceRules?.first,
                splitsSeries: span == .futureEvents && !isFirstOccurrence(event)
            )
        } catch {
            return (false, nil)
        }
        switch change {
        case .remove:
            return (true, "every occurrence of \(title)\(from), since it would stop repeating")
        case .set(let rule):
            return (true, "any occurrence of \(title)\(from) that doesn't fit the new repeat (\(Recurrence.describe(rule)))")
        case nil:
            return (false, nil)
        }
    }

    // MARK: - calendar_open_event

    /// `calendar_open_event`: reveals an event in Calendar.app. Works on read-only calendars.
    public func openEvent(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let event = try fetchEvent(args, span: nil, requireWritable: false)
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

        // Never offer a slot that has already started: "today" parses to midnight,
        // and at 3pm a 9am slot is no use to anyone.
        let startInput = try args.optionalDate("start_date")
        let requestedStart = startInput?.date ?? now
        let searchStart = max(requestedStart, Self.nextQuarterHour(after: now))
        let endInput = try args.optionalDate("end_date")
        let rawEnd = endInput?.date ?? calendar.date(byAdding: .day, value: 6, to: requestedStart) ?? requestedStart
        let searchEnd = (endInput?.hasTime ?? false) ? rawEnd : DateParsing.endOfDay(rawEnd)

        guard searchEnd > requestedStart else {
            throw MacBridgeError.invalidArgument(name: "end_date", reason: "must be after start_date")
        }
        guard searchEnd > searchStart else {
            throw MacBridgeError.invalidArgument(
                name: "end_date",
                reason: "the whole range is in the past; only future times can be offered"
            )
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

        // Birthdays, and the all-day entries on subscribed calendars — public
        // holidays, mostly — would block whole days: one holiday in the range and
        // that day offered nothing, though most people work it. Timed events on
        // a subscribed calendar still block, since a subscribed work or team
        // calendar holds real meetings. Left in when asked for, or when the
        // calendars are named.
        let skipBackground = try names == nil && !args.bool("include_subscribed", default: false)
        var ignored: Set<String> = []

        // Busy = anything not explicitly marked free. All-day events block their
        // whole span, which is what a model should assume when offering times.
        var busy: [DateInterval] = []
        if !calendars.isEmpty {
            let predicate = store.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
            for event in store.events(matching: predicate) {
                guard event.availability != .free, event.status != .canceled else { continue }
                // After the free check, so the note names only calendars that
                // would otherwise have blocked time.
                if skipBackground, let calendar = event.calendar, Self.isBackground(event, in: calendar) {
                    ignored.insert(calendar.title)
                    continue
                }
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

        var out: [String: Value] = [
            "slots": .array(slots),
            "count": .int(slots.count),
            "requested_duration_minutes": .int(duration),
            "searched_from": .string(DateParsing.offsetDateTime.string(from: searchStart)),
            "searched_to": .string(DateParsing.offsetDateTime.string(from: searchEnd)),
            "working_hours": .string(String(format: "%02d:00–%02d:00", dayStart, dayEnd)),
        ]
        if !ignored.isEmpty {
            out["ignored"] = .string(
                "Birthdays and all-day events on subscribed calendars (\(ignored.sorted().joined(separator: ", "))) "
                    + "were not counted as busy. Pass include_subscribed to count them."
            )
        }
        return .object(out)
    }

    /// Something that happens *around* the user rather than to them, so doesn't
    /// make them busy: a birthday, or an all-day entry such as a public holiday
    /// on a subscribed calendar.
    static func isBackground(_ event: EKEvent, in calendar: EKCalendar) -> Bool {
        if calendar.type == .birthday { return true }
        return event.isAllDay && (calendar.type == .subscription || calendar.isSubscribed)
    }

    /// `now` rounded up to :00, :15, :30 or :45, so a slot offered for today starts
    /// at a time a person would propose rather than at 15:07:23.
    static func nextQuarterHour(after now: Date) -> Date {
        let quarter: TimeInterval = 15 * 60
        return Date(timeIntervalSinceReferenceDate:
            (now.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
    }

    // MARK: - Optional fields on create and update

    /// Set whether the event shows as busy, from `availability`.
    private func applyAvailability(_ args: Arguments, to event: EKEvent) throws {
        guard let text = args.optionalString("availability") else { return }
        guard let availability = CalendarMapping.parseAvailability(text) else {
            throw MacBridgeError.invalidArgument(
                name: "availability",
                reason: "expected busy, free, tentative or unavailable"
            )
        }
        // Exchange and some CalDAV servers support only some values; EventKit
        // would otherwise save and quietly keep the old one.
        if let calendar = event.calendar,
           !Self.supports(availability, in: calendar.supportedEventAvailabilities) {
            throw MacBridgeError.invalidArgument(
                name: "availability",
                reason: "the calendar \u{201C}\(calendar.title)\u{201D} doesn't support '\(text)'"
            )
        }
        event.availability = availability
    }

    private static func supports(_ availability: EKEventAvailability, in mask: EKCalendarEventAvailabilityMask) -> Bool {
        switch availability {
        case .busy: return mask.contains(.busy)
        case .free: return mask.contains(.free)
        case .tentative: return mask.contains(.tentative)
        case .unavailable: return mask.contains(.unavailable)
        default: return false
        }
    }

    /// Replace the event's alerts before the start with the one in
    /// `alarm_minutes_before`; null or "" removes them. Alerts at a fixed time or a
    /// place are kept.
    private func applyAlarm(_ args: Arguments, to event: EKEvent) throws {
        guard args.contains("alarm_minutes_before") else { return }
        let minutes: Int?
        if args.isExplicitNull("alarm_minutes_before") || args.clearableString("alarm_minutes_before") == "" {
            minutes = nil
        } else {
            minutes = try args.optionalInt("alarm_minutes_before", in: 0...Self.maxMinutes)
        }
        for alarm in event.alarms ?? [] where alarm.absoluteDate == nil && alarm.structuredLocation == nil {
            event.removeAlarm(alarm)
        }
        if let minutes {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
    }

    /// Remove every alert before the start except one at `minutesBefore`.
    /// Returns whether anything was removed.
    private func keepOnlyAlarm(minutesBefore: Int, on event: EKEvent) -> Bool {
        let wanted = TimeInterval(-minutesBefore * 60)
        var kept = false
        var removed = false
        for alarm in event.alarms ?? [] where alarm.absoluteDate == nil && alarm.structuredLocation == nil {
            if alarm.relativeOffset == wanted && !kept {
                kept = true
            } else {
                event.removeAlarm(alarm)
                removed = true
            }
        }
        return removed
    }

    /// Apply the repeat an update asks for.
    private func applyRepeat(_ args: Arguments, to event: EKEvent, splitsSeries: Bool) throws {
        if event.isDetached && !event.hasRecurrenceRules { try refuseRepeatChange(on: event) }
        switch try Recurrence.change(
            from: args, existing: event.recurrenceRules?.first, splitsSeries: splitsSeries
        ) {
        case .remove:
            for rule in event.recurrenceRules ?? [] { event.removeRecurrenceRule(rule) }
        case .set(let rule):
            event.recurrenceRules = [rule]
        case nil:
            break
        }
    }

    /// Refuse a repeat change on one occurrence before asking for its
    /// occurrence_date, whose absence would otherwise be the error reported.
    /// The fetched event is checked again by ``refuseRepeatChange(on:)``.
    private func requireSeriesSpanForRepeatChange(_ args: Arguments) throws {
        guard let identifier = args.optionalString("event_id") ?? args.optionalString("id"),
              let event = store.event(withIdentifier: identifier),
              Self.repeats(event)
        else { return }
        try refuseRepeatChange(on: event)
    }

    /// The error for a repeat change aimed at one occurrence: a repeat belongs to
    /// a run of occurrences, so it needs span future_events or all_events. One
    /// moved on its own has no repeat of its own to change.
    private func refuseRepeatChange(on event: EKEvent) throws -> Never {
        if event.isDetached && !event.hasRecurrenceRules {
            throw MacBridgeError.invalidArgument(
                name: "recurrence",
                reason: """
                    this occurrence was moved on its own, so it has no repeat to change. \
                    Change the repeat through one of the series' other occurrences.
                    """
            )
        }
        throw MacBridgeError.invalidArgument(
            name: "span",
            reason: """
                changing how an event repeats applies from one occurrence on, not to a single one. \
                Pass span 'future_events' with that occurrence's occurrence_date, or 'all_events' \
                for the whole series.
                """
        )
    }

    /// Whether `event` is its series' first occurrence, which
    /// `event(withIdentifier:)` returns. Unsure counts as not first, so a kept
    /// count is restated rather than silently stretched.
    private func isFirstOccurrence(_ event: EKEvent) -> Bool {
        guard let id = event.eventIdentifier,
              let first = store.event(withIdentifier: id)?.occurrenceDate,
              let this = event.occurrenceDate
        else { return false }
        return abs(first.timeIntervalSince(this)) < 1
    }

    // MARK: - Shared helpers

    /// Which part of a repeating event a write applies to.
    enum Span: String {
        case thisEvent = "this_event"
        case futureEvents = "future_events"
        /// The whole series. EventKit has no such span: it is `.futureEvents`
        /// applied to the first occurrence, which is what `event(withIdentifier:)`
        /// returns for a repeating event.
        case allEvents = "all_events"

        var ekSpan: EKSpan { self == .thisEvent ? .thisEvent : .futureEvents }
    }

    /// Look up the event named by `event_id`, accepting either of the parameter
    /// spellings a model is likely to reach for.
    ///
    /// For a repeating event the id names the whole series — every occurrence
    /// shares it — so `occurrence_date` picks the occurrence. Without one, a write
    /// used to land on whichever occurrence EventKit returned (the first), and
    /// "cancel next Tuesday's standup" deleted an old one instead.
    ///
    /// - Parameters:
    ///   - span: the write's span; nil for a read (`calendar_open_event`), which
    ///     is happy with any occurrence.
    ///   - requireWritable: false for read-only operations. `calendar_open_event`
    ///     only reveals an event in Calendar.app, so demanding a writable calendar
    ///     made it fail with a "read-only" error on exactly the calendars people most
    ///     often want to look at — subscribed holiday and shared calendars.
    private func fetchEvent(_ args: Arguments, span: Span?, requireWritable: Bool = true) throws -> EKEvent {
        let identifier = try args.contains("event_id")
            ? args.requiredString("event_id")
            : args.requiredString("id")

        guard let event = store.event(withIdentifier: identifier) else {
            throw MacBridgeError.notFound(kind: "calendar event", identifier: identifier)
        }
        if requireWritable, let cal = event.calendar {
            try CalendarResolution.requireWritable(cal, kind: "calendar")
        }

        guard Self.repeats(event) else { return event }

        // An occurrence moved on its own gets an id of its own (the series id plus
        // a recurrence-id suffix), and search returns that id for it, so the id
        // alone already names it.
        // Keyed on the id the caller sent, not just the event returned: should a
        // lookup by series id ever answer with a moved first occurrence, a write
        // must still demand occurrence_date rather than land on that one.
        if event.isDetached && !event.hasRecurrenceRules && event.eventIdentifier == identifier {
            if span == .allEvents {
                throw MacBridgeError.invalidArgument(
                    name: "span",
                    reason: """
                        this id names one occurrence that was moved on its own. To change the whole \
                        series, use the id of one of its other occurrences.
                        """
                )
            }
            return event
        }
        // A read with an occurrence_date gets that occurrence, so its details show
        // its own time and anyone's replies to it; without one, any will do.
        guard let span else {
            guard let occurrence = try args.optionalDate("occurrence_date") else { return event }
            return try findOccurrence(of: event, identifier: identifier, at: occurrence.date)
        }
        guard span != .allEvents else { return event }

        guard let occurrence = try args.optionalDate("occurrence_date") else {
            throw MacBridgeError.invalidArgument(
                name: "occurrence_date",
                reason: """
                    '\(event.title ?? "this event")' repeats, and every occurrence shares this id. \
                    Pass the occurrence_date from calendar_search_events to choose the occurrence, \
                    or span 'all_events' to change the whole series.
                    """
            )
        }
        return try findOccurrence(of: event, identifier: identifier, at: occurrence.date)
    }

    /// The occurrence of a repeating event that starts (or originally started, if
    /// it was moved on its own) at `date`.
    ///
    /// Occurrences are matched by `occurrenceMatcher(for:identifier:)`: the series
    /// id, or for one moved on its own, the id it derives from the series id.
    private func findOccurrence(of series: EKEvent, identifier: String, at date: Date) throws -> EKEvent {
        let day: TimeInterval = 24 * 3600
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-day),
            end: date.addingTimeInterval(day),
            calendars: series.calendar.map { [$0] }
        )
        // Within a second, because a model echoes the formatted value back and
        // formatting drops sub-second precision.
        func near(_ other: Date?) -> Bool { other.map { abs($0.timeIntervalSince(date)) < 1 } ?? false }

        let belongs = Self.occurrenceMatcher(for: series, identifier: identifier)
        let candidates = store.events(matching: predicate).filter(belongs)
        guard let match = candidates.first(where: { near($0.occurrenceDate) })
            ?? candidates.first(where: { near($0.startDate) })
            ?? movedOccurrence(matching: belongs, originallyAt: date, in: series.calendar)
        else {
            throw MacBridgeError.invalidArgument(
                name: "occurrence_date",
                reason: """
                    this event has no occurrence at \(DateParsing.offsetDateTime.string(from: date)). \
                    Take occurrence_date from the event as calendar_search_events returns it.
                    """
            )
        }
        return match
    }

    /// An occurrence moved on its own keeps its original `occurrenceDate`, which
    /// is what search reports, but now starts elsewhere — a Tuesday meeting moved
    /// to Thursday is outside the narrow window above. Search a year either side,
    /// well inside EventKit's four-year limit, matching the original date only.
    private func movedOccurrence(
        matching belongs: (EKEvent) -> Bool,
        originallyAt date: Date,
        in calendar: EKCalendar?
    ) -> EKEvent? {
        let year: TimeInterval = 366 * 24 * 3600
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-year),
            end: date.addingTimeInterval(year),
            calendars: calendar.map { [$0] }
        )
        return store.events(matching: predicate).first {
            belongs($0) && $0.occurrenceDate.map { abs($0.timeIntervalSince(date)) < 1 } == true
        }
    }

    /// Whether an event is an occurrence of `series`: it has the series id, or it
    /// is a moved occurrence of it.
    ///
    /// A moved occurrence's id is the series id plus a `/RID=<seconds>` suffix
    /// (seen on macOS 26/27; not documented, so the shared iCalendar UID is checked
    /// too). Both are only trusted within the series' own calendar, which callers
    /// already restrict the search to.
    private static func occurrenceMatcher(for series: EKEvent, identifier: String) -> (EKEvent) -> Bool {
        let uid = series.calendarItemExternalIdentifier
        let movedPrefix = identifier + "/RID="
        return { candidate in
            guard let candidateID = candidate.eventIdentifier else { return false }
            if candidateID == identifier { return true }
            guard candidate.isDetached else { return false }
            if candidateID.hasPrefix(movedPrefix) { return true }
            guard let uid else { return false }
            return candidate.calendarItemExternalIdentifier == uid
        }
    }

    private func resolveSpan(_ args: Arguments) throws -> Span {
        guard let raw = args.optionalString("span") else { return .thisEvent }
        switch raw.lowercased() {
        case "this", "this_event": return .thisEvent
        case "future", "future_events": return .futureEvents
        case "all", "all_events", "series": return .allEvents
        default:
            throw MacBridgeError.invalidArgument(
                name: "span",
                reason: "expected 'this_event', 'future_events' or 'all_events'"
            )
        }
    }

    /// A series, or one occurrence of one. A detached occurrence counts, though
    /// it has no recurrence rules and an id of its own.
    private static func repeats(_ event: EKEvent) -> Bool {
        event.hasRecurrenceRules || event.isDetached
    }

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }
    }
}
