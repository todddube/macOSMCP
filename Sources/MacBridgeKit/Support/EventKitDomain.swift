//
//  EventKitDomain.swift
//  MacBridgeKit · MacBridge
//
//  The macOS domains MacBridge serves, and their tool prefixes.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// The macOS domains MacBridge serves.
///
/// Each maps to one TCC grant against the MacBridge app bundle, and will map to
/// one row per client in the planned consent store.
public enum EventKitDomain: String, Sendable, CaseIterable {
    case calendar
    case reminders

    public var displayName: String {
        switch self {
        case .calendar: return "Calendars"
        case .reminders: return "Reminders"
        }
    }

    /// Prefix shared by every tool in this domain (`domain_verb_object` naming).
    public var toolPrefix: String {
        switch self {
        case .calendar: return "calendar_"
        case .reminders: return "reminders_"
        }
    }
}
