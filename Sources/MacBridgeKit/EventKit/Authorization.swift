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

    /// The current grant for this process, for display. Never prompts.
    ///
    /// Corrects one known lag: right after the user allows the prompt,
    /// `EKEventStore.authorizationStatus(for:)` can go on reporting "not yet
    /// requested" though tccd has recorded the grant. Seen on macOS 27: the panel
    /// kept its Grant button until the app was relaunched. So a "yes" from this
    /// process's own request stands in for that stale answer. Only `.notDetermined`
    /// is overridden; a denial made later in System Settings still comes through.
    ///
    /// ``ensureAccess(to:store:)`` doesn't rely on this override: it asks again on
    /// its own store, so a store is never used without having been granted.
    public static func status(for domain: EventKitDomain) -> EKAuthorizationStatus {
        let reported = systemStatus(for: domain)
        if reported == .notDetermined, grantedInThisProcess.contains(domain),
           let granted = EKAuthorizationStatus(rawValue: 3) {
            // Raw value 3 is .fullAccess on macOS 14+ and .authorized before it; see
            // statusDescription(_:) for why the raw value rather than the case.
            return granted
        }
        return reported
    }

    /// What EventKit itself reports, without the correction in ``status(for:)``.
    private static func systemStatus(for domain: EventKitDomain) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: entityType(for: domain))
    }

    /// Domains a request in this process was told were granted. See ``status(for:)``.
    private static let grantedInThisProcess = DomainSet()

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

    /// True when asking can still change the answer: nothing decided yet, or
    /// write-only access (macOS 14+), which a full-access request offers to upgrade.
    /// A denial or a policy restriction can only be changed outside the app.
    public static func canPrompt(_ status: EKAuthorizationStatus) -> Bool {
        status.rawValue == 0 || status.rawValue == 4
    }

    /// True when a configuration profile controls the domain, so neither the user
    /// nor a prompt can grant it.
    public static func isRestricted(_ status: EKAuthorizationStatus) -> Bool {
        status.rawValue == 1
    }

    /// Request access while asking can still change it (see ``canPrompt(_:)``), then
    /// throw unless we hold it.
    ///
    /// Write-only access is treated as insufficient: every tool here reads back
    /// what it wrote so it can return the item's identifier.
    ///
    /// Decided on EventKit's own status, not the display override in
    /// ``status(for:)``. While that still reads "not yet requested", the request is
    /// made again on `store` every time. Once macOS has decided it returns at once,
    /// with no prompt, and a `true` gives this store its own grant rather than
    /// borrowing one made on another store. It also means a real reset
    /// (`tccutil reset`) prompts again rather than being masked, and a request that
    /// is refused or fails withdraws the display override, so the panel stops
    /// reporting a grant that no longer exists.
    public static func ensureAccess(to domain: EventKitDomain, store: EKEventStore) async throws {
        var current = systemStatus(for: domain)
        var requestError: String?

        if canPrompt(current) {
            do {
                let granted = try await requestAccess(to: domain, store: store)
                // The returned Bool is the one thing that tells a lagging status
                // apart from a real refusal, so it is logged (no user data).
                BridgeLog.debug(
                    "\(domain.displayName) request returned \(granted); status now "
                        + statusDescription(systemStatus(for: domain)),
                    category: .permissions
                )
                if granted {
                    grantedInThisProcess.insert(domain)
                    return
                }
                grantedInThisProcess.remove(domain)
            } catch {
                // Swallowing this was hiding the actual reason a prompt never
                // appeared, which is the single most confusing failure to debug.
                requestError = error.localizedDescription
                grantedInThisProcess.remove(domain)
            }
            current = systemStatus(for: domain)
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

/// A lock-guarded set of domains, shared by every EKEventStore user in the process.
private final class DomainSet: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: Set<EventKitDomain> = []

    func insert(_ domain: EventKitDomain) {
        lock.lock(); defer { lock.unlock() }
        domains.insert(domain)
    }

    func remove(_ domain: EventKitDomain) {
        lock.lock(); defer { lock.unlock() }
        domains.remove(domain)
    }

    func contains(_ domain: EventKitDomain) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return domains.contains(domain)
    }
}
