//
//  MacBridgeError.swift
//  MacBridgeKit · MacBridge
//
//  Errors surfaced to MCP clients as tool-result failures.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Errors surfaced to MCP clients as `isError` tool results.
///
/// Messages are written for a language model reading them: they say what was
/// wrong and, where possible, which tool to call to recover.
public enum MacBridgeError: Error, LocalizedError, Equatable {
    /// A required argument was absent.
    case missingArgument(String)
    /// An argument was present but unusable.
    case invalidArgument(name: String, reason: String)
    /// TCC access to a macOS domain has not been granted.
    case accessDenied(domain: EventKitDomain, status: String, underlying: String? = nil)
    /// A calendar or reminder list could not be resolved by name or id.
    case notFound(kind: String, identifier: String)
    /// The target exists but macOS will not let us write to it.
    case notWritable(kind: String, identifier: String)
    /// EventKit refused a save or delete.
    case saveFailed(underlying: String)
    /// A tool name reached the registry with no handler.
    case unknownTool(String)
    /// The call carried argument names the tool does not take. `suggestions` maps
    /// each unknown name to the likeliest intended one, where there is one.
    case unknownArguments(tool: String, names: [String], suggestions: [String: String], accepted: [String])

    /// The message with every user-supplied value left out — titles, names, ids and
    /// echoed input — for the log file and the unified log, which a user may attach
    /// to a public bug report. The full ``errorDescription`` still reaches the model
    /// and the menu-bar activity list.
    public var logDescription: String {
        switch self {
        case .invalidArgument(let name, _):
            return "Invalid value for '\(name)'."
        case .notFound(let kind, _):
            return "No \(kind) matching the given name or id."
        case .notWritable(let kind, _):
            return "The \(kind) is read-only."
        case .missingArgument, .accessDenied, .saveFailed, .unknownTool, .unknownArguments:
            // Argument names, tool names and macOS's own wording: no calendar data.
            return errorDescription ?? "\(self)"
        }
    }

    /// Where to look for a valid value after a lookup by name or id fails.
    ///
    /// Keyed on the kind rather than a calendar-or-not test, which sent a model
    /// looking for a missing *event* or *reminder* to the list of lists.
    static func recoveryHint(forMissing kind: String) -> String {
        switch kind {
        case "calendar": return "Call calendar_list_calendars to see the available calendars."
        case "calendar event": return "Call calendar_search_events to find the event and its current id."
        case "reminder": return "Call reminders_search_reminders to find the reminder and its current id."
        case "reminder list": return "Call reminders_list_lists to see the available lists."
        case "source": return "Use an account name shown as \"source\" by reminders_list_lists, or omit it."
        default: return "Search again to get a current id."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument '\(name)'."
        case .invalidArgument(let name, let reason):
            return "Invalid value for '\(name)': \(reason)"
        case .accessDenied(let domain, let status, let underlying):
            var message = """
                Access to \(domain.displayName) is \(status). Grant MacBridge access in \
                System Settings → Privacy & Security → \(domain.displayName), then retry.
                """
            if let underlying, !underlying.isEmpty {
                message += " (macOS reported: \(underlying))"
            }
            return message
        case .notFound(let kind, let identifier):
            return "No \(kind) matching '\(identifier)'. \(Self.recoveryHint(forMissing: kind))"
        case .notWritable(let kind, let identifier):
            return "The \(kind) '\(identifier)' is read-only (subscribed or delegated), so it cannot be modified."
        case .saveFailed(let underlying):
            return "macOS rejected the change: \(underlying)"
        case .unknownTool(let name):
            return "Unknown tool '\(name)'."
        case .unknownArguments(let tool, let names, let suggestions, let accepted):
            let listed = names.map { name in
                suggestions[name].map { "'\(name)' (did you mean '\($0)'?)" } ?? "'\(name)'"
            }
            let noun = names.count == 1 ? "argument" : "arguments"
            return """
                \(tool) does not take the \(noun) \(listed.joined(separator: ", ")), and nothing was changed. \
                It accepts: \(accepted.joined(separator: ", ")).
                """
        }
    }
}
