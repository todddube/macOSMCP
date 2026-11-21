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
    /// ``ensureAccess(to:store:timeout:)`` doesn't rely on this override: it asks again on
    /// its own store, so a store is never used without having been granted.
    public static func status(for domain: EventKitDomain) -> EKAuthorizationStatus {
        let reported = systemStatus(for: domain)
        if reported == .notDetermined, grantedInThisProcess.contains(domain) {
            return .fullAccess
        }
        return reported
    }

    /// What EventKit itself reports, without the correction in ``status(for:)``.
    private static func systemStatus(for domain: EventKitDomain) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: entityType(for: domain))
    }

    /// Domains a request in this process was told were granted. See ``status(for:)``.
    fileprivate static let grantedInThisProcess = DomainSet()

    /// How long a lookup that only describes a call, such as a confirmation
    /// prompt's target, waits for access. Once macOS has decided, a request
    /// answers at once; only an undecided one waits, and a full ``requestTimeout``
    /// there, before the alert even appears, would push the call past the
    /// bridge's two-minute limit.
    public static let lookupTimeout: TimeInterval = 5

    /// A short word for the current status, for error messages and `doctor`.
    public static func statusDescription(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not yet requested"
        case .restricted: return "restricted by policy"
        case .denied: return "denied"
        case .fullAccess: return "granted"
        case .writeOnly: return "write-only"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// True when we can both read and write the domain.
    ///
    /// Write-only access is deliberately insufficient: every write tool here reads
    /// the item back so it can return its identifier.
    public static func hasFullAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess
    }

    /// True when asking can still change the answer: nothing decided yet, or
    /// write-only access, which a full-access request offers to upgrade. A denial
    /// or a policy restriction can only be changed outside the app.
    public static func canPrompt(_ status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined || status == .writeOnly
    }

    /// True when a configuration profile controls the domain, so neither the user
    /// nor a prompt can grant it.
    public static func isRestricted(_ status: EKAuthorizationStatus) -> Bool {
        status == .restricted
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
    ///
    /// - Parameter timeout: how long to wait for macOS to answer, or nil to wait as
    ///   long as it takes, as **Grant** does: a person is reading that prompt. A
    ///   tool call keeps the default, so a prompt that can't appear doesn't leave a
    ///   client waiting forever.
    public static func ensureAccess(
        to domain: EventKitDomain,
        store: EKEventStore,
        timeout: TimeInterval? = requestTimeout
    ) async throws {
        var current = systemStatus(for: domain)
        var requestError: String?

        // A store made before the user granted access (the services create theirs at
        // launch) keeps serving the old, empty answer even once the status reads
        // granted. Asking once on each store gives it its own grant: macOS answers a
        // decided request at once, without a prompt.
        if canPrompt(current) || (hasFullAccess(current) && !refreshedStores.contains(store, domain: domain)) {
            do {
                // Logged first so a stall here explains itself in the log.
                BridgeLog.info(
                    "requesting \(domain.displayName) access (status \(statusDescription(current)))",
                    category: .permissions
                )
                let request = inFlight.request(for: domain, on: ObjectIdentifier(store)) {
                    let granted = try await requestAccess(to: domain, store: store)
                    // Recorded here rather than by the caller, which may have
                    // stopped waiting: a prompt answered after a minute still counts.
                    if granted {
                        grantedInThisProcess.insert(domain)
                        // Reset once, here, inside the de-duplicated request: callers
                        // that joined it all wait for this, so none holds EventKit
                        // objects across the reset, and the store is marked
                        // refreshed before any of them can ask again.
                        if hasFullAccess(systemStatus(for: domain)) {
                            store.reset()
                            refreshedStores.insert(store, domain: domain)
                        }
                    } else {
                        grantedInThisProcess.remove(domain)
                    }
                    return granted
                }
                let answer: Bool?
                if let timeout {
                    answer = try await Timeout.run(seconds: timeout) { try await request.value }
                } else {
                    answer = try await request.value
                }
                guard let granted = answer else {
                    BridgeLog.error(
                        "\(domain.displayName) access request unanswered after \(Int(timeout ?? 0))s",
                        category: .permissions
                    )
                    throw MacBridgeError.accessPending(domain: domain, seconds: Int(timeout ?? 0))
                }
                // The returned Bool is the one thing that tells a lagging status
                // apart from a real refusal, so it is logged (no user data).
                BridgeLog.debug(
                    "\(domain.displayName) request returned \(granted); status now "
                        + statusDescription(systemStatus(for: domain)),
                    category: .permissions
                )
                // The request records its own answer, and resets and marks the store,
                // so one that arrives after a timeout counts too.
                if granted { return }
            } catch let error as MacBridgeError where error.isAccessPending {
                throw error
            } catch is CancellationError {
                throw CancellationError()
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

    /// How long to wait for macOS to answer an access request.
    ///
    /// Without a limit, a request whose prompt can't be shown — `mcp --direct`
    /// run from a process with no window, after a rebuild changed the signature —
    /// never returned, and the client waited forever on a call that logged
    /// nothing. Long enough to read and answer a prompt that does appear.
    public static let requestTimeout: TimeInterval = 60

    /// Stores that have asked once since access was granted. See ``ensureAccess(to:store:timeout:)``.
    fileprivate static let refreshedStores = StoreSet()

    /// The request waiting for an answer, per domain and store.
    private static let inFlight = InFlightRequests()

    private static func requestAccess(to domain: EventKitDomain, store: EKEventStore) async throws -> Bool {
        switch domain {
        case .calendar: return try await store.requestFullAccessToEvents()
        case .reminders: return try await store.requestFullAccessToReminders()
        }
    }
}

/// One access request at a time per domain and store.
///
/// Without this, every tool call made while a prompt was unanswered asked macOS
/// again, waited out its own timeout, and left another request behind. A call
/// now waits on the one its store already made. Each service owns one store, so
/// its calls share; a different store, such as the fresh one **Grant** makes,
/// always asks for itself. Joining another store's request would report a grant
/// that this store doesn't hold, which is what the per-store request in
/// ``EventKitAuthorization/ensureAccess(to:store:timeout:)`` exists to avoid.
/// A request is forgotten once answered, so the next call asks afresh.
final class InFlightRequests: @unchecked Sendable {
    private struct Key: Hashable {
        let domain: EventKitDomain
        let store: ObjectIdentifier
    }

    private let lock = NSLock()
    private var requests: [Key: Task<Bool, Error>] = [:]

    /// The request waiting for `domain` on `store`, or a new one made with `make`.
    func request(
        for domain: EventKitDomain,
        on store: ObjectIdentifier,
        make: @escaping @Sendable () async throws -> Bool
    ) -> Task<Bool, Error> {
        let key = Key(domain: domain, store: store)
        lock.lock(); defer { lock.unlock() }
        if let existing = requests[key] { return existing }
        let task = Task<Bool, Error> {
            defer { self.finish(key) }
            return try await make()
        }
        requests[key] = task
        return task
    }

    /// How many requests are waiting, for tests.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    private func finish(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        requests[key] = nil
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

/// Stores already refreshed after a grant, held weakly so a dropped store is forgotten.
private final class StoreSet: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [EventKitDomain: NSHashTable<EKEventStore>] = [:]

    private func table(_ domain: EventKitDomain) -> NSHashTable<EKEventStore> {
        if let t = tables[domain] { return t }
        let t = NSHashTable<EKEventStore>(options: [.weakMemory, .objectPointerPersonality])
        tables[domain] = t
        return t
    }

    func insert(_ store: EKEventStore, domain: EventKitDomain) {
        lock.lock(); defer { lock.unlock() }
        table(domain).add(store)
    }

    func contains(_ store: EKEventStore, domain: EventKitDomain) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return table(domain).contains(store)
    }
}
