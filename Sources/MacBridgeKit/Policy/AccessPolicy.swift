//
//  AccessPolicy.swift
//  MacBridgeKit · MacBridge
//
//  What connected clients may do: read-only mode and confirmation before deleting.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// What connected clients may do, as the user set it in the menu-bar panel.
///
/// Decides each call before it runs: allow it, refuse it with a message the model
/// can relay, or hold it for the user to confirm. The app shows the confirmation;
/// this type only says one is needed, so it stays terminal-testable.
///
/// Stored in the app's defaults, which `macbridge mcp --direct` reads too, so a
/// client can't step around Read-only by running without the app.
public struct AccessPolicy: Equatable, Sendable {

    /// Refuse every tool that changes data. Reads, and revealing an item in
    /// Calendar or Reminders, still work.
    public var readOnly: Bool

    /// Ask the user before running a destructive tool (delete or cancel).
    public var confirmDestructive: Bool

    /// The defaults: everything allowed, deleting confirmed.
    public init(readOnly: Bool = false, confirmDestructive: Bool = true) {
        self.readOnly = readOnly
        self.confirmDestructive = confirmDestructive
    }

    /// What to do with one call.
    public enum Decision: Equatable, Sendable {
        case allow
        /// Refuse, with the message the model should see.
        case refuse(String)
        /// Run only if the user approves it.
        case confirm
    }

    /// The decision for a call to `tool`.
    public func decision(for tool: String) -> Decision {
        if readOnly && ToolRegistry.changesData(tool) {
            return .refuse(Self.readOnlyRefusal(tool))
        }
        if confirmDestructive && ToolRegistry.destructiveToolNames.contains(tool) {
            return .confirm
        }
        return .allow
    }

    // MARK: Messages
    // Written for the model: what happened, that nothing changed, and what the user
    // can do, so it reports back instead of retrying or trying another tool.

    static func readOnlyRefusal(_ tool: String) -> String {
        """
        MacBridge is in read-only mode, so \(tool) was not run and nothing was changed. \
        Tell the user; they can turn off Read-only in the MacBridge menu-bar panel.
        """
    }

    /// The user pressed Don't Allow.
    public static func declined(_ tool: String) -> String {
        """
        The user declined \(tool) in MacBridge's confirmation, so nothing was changed. \
        Don't call it again unless the user asks you to.
        """
    }

    /// Nobody answered before the confirmation gave up.
    public static func timedOut(_ tool: String) -> String {
        """
        Nobody answered MacBridge's confirmation for \(tool) in time, so it was not run and \
        nothing was changed. Ask the user to watch for the MacBridge prompt, then try again.
        """
    }

    /// The app couldn't apply the policy at all; refuse rather than allow.
    public static let unavailable =
        "MacBridge couldn't check whether this call is allowed, so it was not run and nothing was changed."

    /// `mcp --direct` has no app to show a confirmation in.
    public static func cannotConfirm(_ tool: String) -> String {
        """
        \(tool) needs the user's confirmation, which `macbridge mcp --direct` has no way to \
        show, so nothing was changed. Run MacBridge through the app (`macbridge mcp`), or \
        turn off Ask before deleting in the MacBridge menu-bar panel.
        """
    }

    // MARK: Storage

    private static let readOnlyKey = "accessPolicy.readOnly"
    private static let confirmDestructiveKey = "accessPolicy.confirmDestructive"

    /// The app's own defaults domain, from either face of the binary.
    ///
    /// Inside the app (or the `macbridge` executable in its bundle, which shares its
    /// bundle identifier) that is `.standard`. A SwiftPM-built CLI has an identifier
    /// of its own, so it reads the release app's domain by name.
    public static var sharedDefaults: UserDefaults {
        let appDomain = "com.thedubes.macbridge"
        if let id = Bundle.main.bundleIdentifier, id == appDomain || id == appDomain + ".debug" {
            return .standard
        }
        return UserDefaults(suiteName: appDomain) ?? .standard
    }

    /// The stored policy, or the defaults where nothing is stored.
    public static func load(from defaults: UserDefaults = sharedDefaults) -> AccessPolicy {
        AccessPolicy(
            readOnly: defaults.bool(forKey: readOnlyKey),
            confirmDestructive: defaults.object(forKey: confirmDestructiveKey) as? Bool ?? true
        )
    }

    /// Store this policy.
    public func save(to defaults: UserDefaults = sharedDefaults) {
        defaults.set(readOnly, forKey: Self.readOnlyKey)
        defaults.set(confirmDestructive, forKey: Self.confirmDestructiveKey)
    }
}
