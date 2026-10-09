//
//  Authorization.swift
//  MacBridgeKit · MacBridge
//
//  TCC authorization for the EventKit domains.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import EventKit
import Foundation

/// TCC authorization for the EventKit domains.
///
/// Every EventKit call happens inside MacBridge.app, so the grant attaches to the
/// app bundle once and the CLI shim never prompts at all. The exception is
/// `macbridge mcp --direct`, which does the work in the CLI process and therefore
/// prompts as itself.
public enum EventKitAuthorization {

    /// The EventKit entity type a domain's TCC grant covers.
    public static func entityType(for domain: EventKitDomain) -> EKEntityType {
        switch domain {
        case .calendar: return .event
        case .reminders: return .reminder
        }
    }

    /// The current grant for this process. Never prompts.
    public static func status(for domain: EventKitDomain) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: entityType(for: domain))
    }

    /// A short word for the current status, for error messages and `doctor`.
    ///
    /// Mapped from the raw value rather than switched on the enum: macOS 14 added
    /// `.fullAccess` — which reuses `.authorized`'s raw value of 3 — and
    /// `.writeOnly`. Building against a newer SDK than the deployment target makes
    /// any switch over the cases either non-exhaustive or a reference to symbols
    /// the target does not have.
    public static func statusDescription(_ status: EKAuthorizationStatus) -> String {
        switch status.rawValue {
        case 0: return "not yet requested"
        case 1: return "restricted by policy"
        case 2: return "denied"
        case 3: return "granted"
        case 4: return "write-only"
        default: return "unknown (\(status.rawValue))"
        }
    }

    /// True when we can both read and write the domain.
    ///
    /// Write-only access (macOS 14+) is deliberately insufficient: every write
    /// tool here reads the item back so it can return its identifier.
    public static func hasFullAccess(_ status: EKAuthorizationStatus) -> Bool {
        status.rawValue == 3
    }

    /// Request access if it has not been decided, then throw unless we hold it.
    ///
    /// Write-only access is treated as insufficient: every tool here reads back
    /// what it wrote so it can return the item's identifier.
    public static func ensureAccess(to domain: EventKitDomain, store: EKEventStore) async throws {
        var current = status(for: domain)
        var requestError: String?

        if current == .notDetermined {
            do {
                _ = try await requestAccess(to: domain, store: store)
            } catch {
                // Swallowing this was hiding the actual reason a prompt never
                // appeared, which is the single most confusing failure to debug.
                requestError = error.localizedDescription
            }
            current = status(for: domain)
        }

        guard hasFullAccess(current) else {
            throw MacBridgeError.accessDenied(
                domain: domain,
                status: statusDescription(current),
                underlying: requestError
            )
        }
    }

    private static func requestAccess(to domain: EventKitDomain, store: EKEventStore) async throws -> Bool {
        if #available(macOS 14.0, *) {
            switch domain {
            case .calendar: return try await store.requestFullAccessToEvents()
            case .reminders: return try await store.requestFullAccessToReminders()
            }
        } else {
            return try await store.requestAccess(to: entityType(for: domain))
        }
    }
}
