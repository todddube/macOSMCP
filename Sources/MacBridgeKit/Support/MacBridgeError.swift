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
            return "No \(kind) matching '\(identifier)'. Call \(kind == "calendar" ? "calendar_list_calendars" : "reminders_list_lists") to see the available options."
        case .notWritable(let kind, let identifier):
            return "The \(kind) '\(identifier)' is read-only (subscribed or delegated), so it cannot be modified."
        case .saveFailed(let underlying):
            return "macOS rejected the change: \(underlying)"
        case .unknownTool(let name):
            return "Unknown tool '\(name)'."
        }
    }
}
