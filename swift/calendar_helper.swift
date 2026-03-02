#!/usr/bin/env swift
//
// calendar_helper — Fast calendar event queries via EventKit.
//
// Replaces the slow AppleScript `whose` date filter (O(N) scan over all
// historical events) with EventKit's predicateForEvents (O(log N) indexed).
//
// Usage:
//   calendar_helper --start YYYY-MM-DD --end YYYY-MM-DD [--calendar NAME] [--search QUERY] [--limit N]
//
// Output: TSV lines (one per event) with key=value fields:
//   cal=<name>\ttitle=<title>\tstart=<date>\tend=<date>\tallday=<true|false>[\tlocation=<loc>][\tnotes=<notes>]
//
// Notes field is always last. Newlines in notes are replaced with " | ".
//

import EventKit
import Foundation

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

func parseArgs() -> (start: Date, end: Date, calendar: String?, search: String?, limit: Int) {
    let args = CommandLine.arguments
    var startDate: Date?
    var endDate: Date?
    var calendarName: String?
    var searchQuery: String?
    var limit = 200

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--start":
            i += 1
            if i < args.count {
                startDate = formatter.date(from: args[i])
            }
        case "--end":
            i += 1
            if i < args.count {
                if var d = formatter.date(from: args[i]) {
                    // Set to end of day (23:59:59)
                    d = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
                    endDate = d
                }
            }
        case "--calendar":
            i += 1
            if i < args.count { calendarName = args[i] }
        case "--search":
            i += 1
            if i < args.count { searchQuery = args[i] }
        case "--limit":
            i += 1
            if i < args.count { limit = Int(args[i]) ?? 200 }
        default:
            break
        }
        i += 1
    }

    guard let s = startDate, let e = endDate else {
        fputs("ERROR:--start and --end are required (YYYY-MM-DD)\n", stderr)
        exit(1)
    }
    return (s, e, calendarName, searchQuery, limit)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let (startDate, endDate, calendarFilter, searchQuery, limit) = parseArgs()

let store = EKEventStore()

// Request calendar access (synchronous via semaphore)
let semaphore = DispatchSemaphore(value: 0)
var accessGranted = false

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, error in
        accessGranted = granted
        if let error = error {
            fputs("ERROR:Calendar access denied: \(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
} else {
    store.requestAccess(to: .event) { granted, error in
        accessGranted = granted
        if let error = error {
            fputs("ERROR:Calendar access denied: \(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
}
semaphore.wait()

guard accessGranted else {
    fputs("ERROR:Calendar access not granted\n", stderr)
    exit(1)
}

// Build calendar list (exclude "Scheduled Reminders" unless specifically requested)
var calendars: [EKCalendar]
if let name = calendarFilter {
    calendars = store.calendars(for: .event).filter { $0.title == name }
    if calendars.isEmpty {
        fputs("ERROR:Calendar '\(name)' not found\n", stderr)
        exit(1)
    }
} else {
    calendars = store.calendars(for: .event).filter { $0.title != "Scheduled Reminders" }
}

// Query events using indexed predicate (fast!)
let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
var events = store.events(matching: predicate)

// Optional title search filter
if let query = searchQuery {
    let lowerQuery = query.lowercased()
    events = events.filter { $0.title?.lowercased().contains(lowerQuery) == true }
}

// Apply limit
let capped = events.prefix(limit)

// Date formatter for output (matches AppleScript's date string format)
let outFormatter = DateFormatter()
outFormatter.dateStyle = .full
outFormatter.timeStyle = .medium
outFormatter.timeZone = TimeZone.current

// Output TSV
for event in capped {
    var fields: [String] = []
    fields.append("cal=\(event.calendar.title)")
    fields.append("title=\(event.title ?? "")")
    fields.append("start=\(outFormatter.string(from: event.startDate))")
    fields.append("end=\(outFormatter.string(from: event.endDate))")
    fields.append("allday=\(event.isAllDay)")

    if let loc = event.location, !loc.isEmpty {
        fields.append("location=\(loc)")
    }

    // Notes is always last (may contain tabs — parser rejoins tail)
    if let notes = event.notes, !notes.isEmpty {
        let cleaned = notes.replacingOccurrences(of: "\n", with: " | ")
            .replacingOccurrences(of: "\r", with: "")
        fields.append("notes=\(cleaned)")
    }

    print(fields.joined(separator: "\t"))
}
