//
//  ActivitySummary.swift
//  MacBridgeKit · MacBridge
//
//  Turns a tool result into a few words for the activity list.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MCP

/// A short description of what a tool call actually did.
///
/// Without this the activity list shows only a tool name, so a search that found
/// fourteen lists looks identical to one that found nothing — which defeats the
/// point of showing the call at all.
public enum ActivitySummary {

    /// Result keys that carry a collection, and the noun to report them as.
    private static let collections: [(key: String, singular: String, plural: String)] = [
        ("calendars", "calendar", "calendars"),
        ("events", "event", "events"),
        ("lists", "list", "lists"),
        ("reminders", "reminder", "reminders"),
        ("slots", "slot", "slots"),
    ]

    /// Verbs a write tool reports, in the order they should be preferred.
    private static let verbs = [
        "created", "updated", "deleted", "cancelled", "rescheduled", "opened", "completed",
    ]

    /// A few words describing `result`, or nil when nothing useful can be said.
    public static func summarize(_ result: Value) -> String? {
        guard let fields = result.objectValue else { return nil }

        // Writes: say what happened to what, which is the part worth seeing.
        for verb in verbs where fields[verb]?.boolValue == true {
            if let title = title(in: fields) {
                return "\(verb) \u{201C}\(title)\u{201D}"
            }
            return verb
        }

        // `completed` is a Bool on the complete tool rather than a flag, so it needs
        // reading rather than testing for truth.
        if let completed = fields["completed"]?.boolValue, fields["reminder"] != nil {
            let action = completed ? "completed" : "reopened"
            if let title = title(in: fields) { return "\(action) \u{201C}\(title)\u{201D}" }
            return action
        }

        // Reads: the count, and what of.
        for collection in collections {
            guard let items = fields[collection.key]?.arrayValue else { continue }
            let total = fields["total_matched"]?.intValue
            let noun = items.count == 1 ? collection.singular : collection.plural

            if let total, total > items.count {
                return "\(items.count) of \(total) \(collection.plural)"
            }
            return "\(items.count) \(noun)"
        }

        return nil
    }

    /// The title of whatever the result is about, from the result or its payload.
    private static func title(in fields: [String: Value]) -> String? {
        if let direct = fields["title"]?.stringValue { return direct }
        for key in ["event", "reminder", "list"] {
            if let title = fields[key]?.objectValue?["title"]?.stringValue { return title }
        }
        return nil
    }

    /// `1.2s` / `340ms`, or nil when the call was too quick to be interesting.
    public static func describe(duration: TimeInterval) -> String? {
        guard duration >= 0.1 else { return nil }
        if duration >= 1 { return String(format: "%.1fs", duration) }
        return "\(Int(duration * 1000))ms"
    }
}
