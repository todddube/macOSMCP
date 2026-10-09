//
//  RemindersService.swift
//  MacBridgeKit · MacBridge
//
//  Every Reminders operation, backed by EventKit.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation
import MCP

/// Every Reminders operation, backed by EventKit.
///
/// An actor for the same reason as `CalendarService`: `EKEventStore` is neither
/// thread-safe nor Sendable, and no EventKit object escapes these methods.
public actor RemindersService {

    private let store = EKEventStore()
    private let domain = EventKitDomain.reminders

    /// Creates a service with its own `EKEventStore`; access is requested on first use.
    public init() {}

    private func ensureAccess() async throws {
        try await EventKitAuthorization.ensureAccess(to: domain, store: store)
    }

    /// `fetchReminders` is the one callback-based EventKit API in use; everything
    /// downstream is ordinary async.
    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - reminders_list_lists

    /// `reminders_list_lists`: every reminder list, with incomplete counts by default.
    public func listLists(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        // Not cached: incomplete counts are the default and go stale the moment a
        // reminder is completed — including by a tool call in the same conversation.
        let includeCounts = try args.bool("include_counts", default: true)
        let calendars = CalendarResolution.reminderCalendars(in: store)

        var mapped: [Value] = []
        if includeCounts {
            // One fetch across every list, then tallied locally — far cheaper than
            // a predicate per list, which gets slow on accounts with many lists.
            let incomplete = await fetch(
                store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: calendars
                )
            )
            var counts: [String: Int] = [:]
            for reminder in incomplete {
                guard let id = reminder.calendar?.calendarIdentifier else { continue }
                counts[id, default: 0] += 1
            }
            mapped = calendars.map {
                ReminderMapping.list($0, incompleteCount: counts[$0.calendarIdentifier] ?? 0)
            }
        } else {
            mapped = calendars.map { ReminderMapping.list($0) }
        }

        var out: [String: Value] = [
            "lists": .array(mapped),
            "count": .int(mapped.count),
        ]
        if let defaultList = store.defaultCalendarForNewReminders()?.title {
            out["default"] = .string(defaultList)
        }
        return .object(out)
    }

    // MARK: - reminders_search_reminders

    /// One query tool covering every read: all reminders on a list, a text search,
    /// what is overdue, what is coming up, and the full detail of a single item.
    /// A model picks parameters more reliably than it picks between five
    /// near-identical tools.
    public func searchReminders(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let now = Date()
        let includeCompleted = try args.bool("include_completed", default: false)

        let names = args.optionalStringArray("lists") ?? args.optionalStringArray("list")
        let calendars = try CalendarResolution.resolveSubset(
            names: names,
            among: CalendarResolution.reminderCalendars(in: store),
            kind: "reminder list"
        )
        guard !calendars.isEmpty else {
            return .object(["reminders": .array([]), "count": .int(0),
                            "warning": .string("No reminder lists available to search.")])
        }

        let predicate = includeCompleted
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars
            )

        var reminders = await fetch(predicate)

        // An explicit id lookup short-circuits every other filter — this is the
        // get_reminder_detail path.
        if let id = args.optionalString("reminder_id") {
            guard let match = reminders.first(where: { $0.calendarItemIdentifier == id })
                ?? store.calendarItem(withIdentifier: id) as? EKReminder
            else {
                throw MacBridgeError.notFound(kind: "reminder", identifier: id)
            }
            return .object([
                "reminders": .array([ReminderMapping.reminder(match, now: now)]),
                "count": .int(1),
            ])
        }

        if let query = args.optionalString("query") {
            let needle = query.lowercased()
            reminders = reminders.filter {
                ($0.title?.lowercased().contains(needle) ?? false)
                    || ($0.notes?.lowercased().contains(needle) ?? false)
            }
        }

        if try args.bool("overdue", default: false) {
            reminders = reminders.filter { !$0.isCompleted && isOverdue($0, now: now) }
        }
        if let hasDue = try args.optionalBool("has_due_date") {
            reminders = reminders.filter { ($0.dueDateComponents != nil) == hasDue }
        }
        if let before = try args.optionalDate("due_before") {
            // A date-only bound reads as "through the end of that day".
            let bound = before.hasTime ? before.date : DateParsing.endOfDay(before.date)
            reminders = reminders.filter { dueDate($0).map { $0 <= bound } ?? false }
        }
        if let after = try args.optionalDate("due_after") {
            let bound = after.hasTime ? after.date : Calendar.current.startOfDay(for: after.date)
            reminders = reminders.filter { dueDate($0).map { $0 >= bound } ?? false }
        }
        if let days = try args.optionalInt("due_within_days") {
            guard days >= 0 else {
                throw MacBridgeError.invalidArgument(name: "due_within_days", reason: "must not be negative")
            }
            let horizon = DateParsing.endOfDay(
                Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
            )
            reminders = reminders.filter { dueDate($0).map { $0 <= horizon } ?? false }
        }

        // Undated reminders sort last rather than first: "what's next" should not
        // open with everything that has no date.
        reminders.sort { lhs, rhs in
            let l = dueDate(lhs) ?? .distantFuture
            let r = dueDate(rhs) ?? .distantFuture
            if l != r { return l < r }
            return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
        }

        let total = reminders.count
        let offset = try args.int("offset", default: 0, in: 0...100_000)
        let limit = try args.int("limit", default: 50, in: 1...500)
        let page = reminders.dropFirst(offset).prefix(limit)

        var out: [String: Value] = [
            "reminders": .array(page.map { ReminderMapping.reminder($0, now: now) }),
            "count": .int(page.count),
            "total_matched": .int(total),
        ]
        if offset > 0 { out["offset"] = .int(offset) }
        if let query = args.optionalString("query") { out["query"] = .string(query) }
        if names != nil { out["lists_searched"] = .array(calendars.map { .string($0.title) }) }
        if offset + page.count < total { out["truncated"] = .bool(true) }
        return .object(out)
    }

    private func dueDate(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return Calendar.current.date(from: components)
    }

    private func isOverdue(_ reminder: EKReminder, now: Date) -> Bool {
        guard let due = dueDate(reminder) else { return false }
        // A date-only due is not late until the day is over.
        let deadline = reminder.dueDateComponents?.hour == nil ? DateParsing.endOfDay(due) : due
        return deadline < now
    }

    // MARK: - reminders_create_reminder

    /// `reminders_create_reminder`: a new reminder on the named or default list. A
    /// timed due date also gets an alarm unless `alarm` is false.
    public func createReminder(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let reminder = EKReminder(eventStore: store)
        reminder.title = try args.requiredString("title")

        let calendars = CalendarResolution.reminderCalendars(in: store)
        if let requested = args.optionalString("list") {
            let cal = try CalendarResolution.resolve(identifier: requested, among: calendars, kind: "reminder list")
            try CalendarResolution.requireWritable(cal, kind: "reminder list")
            reminder.calendar = cal
        } else if let fallback = store.defaultCalendarForNewReminders() {
            reminder.calendar = fallback
        } else {
            guard let firstWritable = calendars.first(where: { $0.allowsContentModifications }) else {
                throw MacBridgeError.notFound(kind: "reminder list", identifier: "any writable list")
            }
            reminder.calendar = firstWritable
        }

        if let due = try args.optionalDate("due") {
            setDue(due, on: reminder)
            // Without an alarm a timed reminder never actually notifies, which is
            // almost never what someone asking for a due time wants.
            if due.hasTime, try args.bool("alarm", default: true) {
                reminder.addAlarm(EKAlarm(absoluteDate: due.date))
            }
        }
        if let notes = args.optionalString("notes") { reminder.notes = notes }
        if let urlString = args.optionalString("url") { reminder.url = URL(string: urlString) }
        if let priority = try ReminderMapping.parsePriority(args) { reminder.priority = priority }
        if let rule = try Recurrence.rule(from: args) { reminder.addRecurrenceRule(rule) }

        try save(reminder)

        return .object([
            "created": .bool(true),
            "reminder": ReminderMapping.reminder(reminder),
        ])
    }

    // MARK: - reminders_update_reminder

    /// `reminders_update_reminder`: patches a reminder. Absent keys are left alone;
    /// an explicit null or empty string clears a clearable field.
    public func updateReminder(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let reminder = try fetchReminder(args)

        if let title = args.optionalString("title") { reminder.title = title }

        if args.contains("due") {
            if args.isExplicitNull("due") || args.optionalString("due") == nil {
                reminder.dueDateComponents = nil
                clearAlarms(on: reminder)
            } else if let due = try args.optionalDate("due") {
                setDue(due, on: reminder)

                // The old absolute alarm has to go with the old due date, or
                // "move my 2pm reminder to 5pm" keeps notifying at 2pm and never
                // fires at 5pm.
                clearAlarms(on: reminder)
                if due.hasTime, try args.bool("alarm", default: true) {
                    reminder.addAlarm(EKAlarm(absoluteDate: due.date))
                }
            }
        }
        if let notes = args.clearableString("notes") {
            reminder.notes = notes.isEmpty ? nil : notes
        }
        if let urlString = args.clearableString("url") {
            reminder.url = urlString.isEmpty ? nil : URL(string: urlString)
        }
        if let priority = try ReminderMapping.parsePriority(args) {
            reminder.priority = priority
        }
        if let completed = try args.optionalBool("completed") {
            setCompleted(completed, on: reminder)
        }
        if args.contains("list"), let requested = args.optionalString("list") {
            let cal = try CalendarResolution.resolve(
                identifier: requested,
                among: CalendarResolution.reminderCalendars(in: store),
                kind: "reminder list"
            )
            try CalendarResolution.requireWritable(cal, kind: "reminder list")
            reminder.calendar = cal
        }

        try save(reminder)

        return .object([
            "updated": .bool(true),
            "reminder": ReminderMapping.reminder(reminder),
        ])
    }

    // MARK: - reminders_complete_reminder

    /// Completing and un-completing share a tool because "actually, not done"
    /// is a normal correction and should not need a different verb.
    public func completeReminder(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let reminder = try fetchReminder(args)
        let completed = try args.bool("completed", default: true)

        let wasCompleted = reminder.isCompleted
        setCompleted(completed, on: reminder)
        try save(reminder)

        return .object([
            "completed": .bool(completed),
            "changed": .bool(wasCompleted != completed),
            "reminder": ReminderMapping.reminder(reminder),
        ])
    }

    // MARK: - reminders_delete_reminder

    /// `reminders_delete_reminder`: removes a reminder for good. Irreversible; the
    /// result echoes what was removed.
    public func deleteReminder(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let reminder = try fetchReminder(args)
        let summary = ReminderMapping.reminder(reminder)
        let title = reminder.title ?? "(no title)"

        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "deleted": .bool(true),
            "title": .string(title),
            "reminder": summary,
        ])
    }

    // MARK: - reminders_open_reminder

    /// `reminders_open_reminder`: reveals a reminder in Reminders.app. Works on read-only lists.
    public func openReminder(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let reminder = try fetchReminder(args, requireWritable: false)
        try Reveal.open(Reveal.reminderURL(identifier: reminder.calendarItemIdentifier))

        return .object([
            "opened": .bool(true),
            "title": .string(reminder.title ?? "(no title)"),
        ])
    }

    // MARK: - reminders_create_list

    /// `reminders_create_list`: a new list, in the named account or the default list's.
    public func createList(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let title = try args.requiredString("title")
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title

        // A new calendar must be attached to a source that accepts reminders.
        // Preferring the default list's source puts it where the existing lists
        // live (iCloud for most people) rather than local-only.
        if let requested = args.optionalString("source") {
            guard let source = store.sources.first(where: {
                $0.title.caseInsensitiveCompare(requested) == .orderedSame
            }) else {
                throw MacBridgeError.notFound(kind: "source", identifier: requested)
            }
            calendar.source = source
        } else if let source = store.defaultCalendarForNewReminders()?.source {
            calendar.source = source
        } else if let source = store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = source
        } else {
            throw MacBridgeError.saveFailed(underlying: "no account is available to hold a new list")
        }

        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "created": .bool(true),
            "list": ReminderMapping.list(calendar, incompleteCount: 0),
        ])
    }

    // MARK: - reminders_update_list

    /// `reminders_update_list`: renames a list.
    public func updateList(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let calendar = try fetchList(args)
        let newTitle = try args.requiredString("title")
        let oldTitle = calendar.title
        calendar.title = newTitle

        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "updated": .bool(true),
            "renamed_from": .string(oldTitle),
            "list": ReminderMapping.list(calendar),
        ])
    }

    // MARK: - reminders_delete_list

    /// `reminders_delete_list`: removes a list and every reminder on it. Irreversible;
    /// the result reports how many reminders went with it.
    public func deleteList(_ args: Arguments) async throws -> Value {
        try await ensureAccess()

        let calendar = try fetchList(args)
        let title = calendar.title

        // Deleting a list takes its reminders with it, so the count goes in the
        // result — and will go into the confirmation sheet.
        let contained = await fetch(store.predicateForReminders(in: [calendar])).count

        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }

        return .object([
            "deleted": .bool(true),
            "title": .string(title),
            "reminders_deleted": .int(contained),
        ])
    }

    // MARK: - Shared helpers

    private func fetchReminder(_ args: Arguments, requireWritable: Bool = true) throws -> EKReminder {
        let identifier = try args.contains("reminder_id")
            ? args.requiredString("reminder_id")
            : args.requiredString("id")

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw MacBridgeError.notFound(kind: "reminder", identifier: identifier)
        }
        if requireWritable, let cal = reminder.calendar {
            try CalendarResolution.requireWritable(cal, kind: "reminder list")
        }
        return reminder
    }

    private func fetchList(_ args: Arguments) throws -> EKCalendar {
        let identifier = try args.contains("list_id")
            ? args.requiredString("list_id")
            : args.requiredString("list")

        let calendar = try CalendarResolution.resolve(
            identifier: identifier,
            among: CalendarResolution.reminderCalendars(in: store),
            kind: "reminder list"
        )
        try CalendarResolution.requireWritable(calendar, kind: "reminder list")
        return calendar
    }

    /// Reminders store their due date as components, not an instant: omitting the
    /// time fields is what makes a reminder all-day in Reminders.app.
    private func setDue(_ due: (date: Date, hasTime: Bool), on reminder: EKReminder) {
        let units: Set<Calendar.Component> = due.hasTime
            ? [.year, .month, .day, .hour, .minute, .second]
            : [.year, .month, .day]
        reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due.date)
    }

    private func clearAlarms(on reminder: EKReminder) {
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
    }

    /// `isCompleted` and `completionDate` must move together; setting only the
    /// flag leaves a stale date behind that Reminders.app displays.
    private func setCompleted(_ completed: Bool, on reminder: EKReminder) {
        if completed {
            reminder.isCompleted = true
            if reminder.completionDate == nil { reminder.completionDate = Date() }
        } else {
            reminder.completionDate = nil
            reminder.isCompleted = false
        }
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacBridgeError.saveFailed(underlying: error.localizedDescription)
        }
    }
}
