//
//  LaunchAtLogin.swift
//  MacBridge (app) · MacBridge
//
//  Registers the app as a login item, so the bridge is up after a restart.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation
import MacBridgeKit
import ServiceManagement

/// Whether macOS opens MacBridge when the user logs in.
///
/// Backed by `SMAppService.mainApp` (macOS 13+), which registers this bundle itself
/// as a login item: no helper app, no LaunchAgent plist. The registration lives in
/// macOS, not in UserDefaults, so ``status`` is read back from the system every time
/// — the user can also switch it off in System Settings → General → Login Items, and
/// the panel has to reflect that rather than a remembered checkbox.
///
/// A login item points at a bundle by location, so it is only offered for a copy in
/// an Applications folder. A DerivedData build or a copy on a disk image would
/// register a path that later vanishes.
@MainActor
enum LaunchAtLogin {

    /// The login-item state as the panel shows it, folding `SMAppService.Status`'s
    /// `.notRegistered` and `.notFound` into one "off".
    enum Status: Equatable {
        /// Registered and allowed: MacBridge opens at login.
        case enabled
        /// Not registered.
        case disabled
        /// Registered, but switched off in System Settings → Login Items. Only the
        /// user can allow it there; the app can't.
        case requiresApproval
    }

    /// What macOS currently has on record for this bundle.
    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // .notFound is what an app that has never registered can report; to the
        // user it's the same as off.
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Whether this copy is somewhere a login item can safely point at.
    static var isAvailable: Bool {
        let bundle = Bundle.main.bundleURL
        return InstallPolicy.isInstalled(
            bundlePath: bundle.path,
            resolvedPath: bundle.resolvingSymlinksInPath().path,
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Register or unregister the login item. A no-op when already in that state,
    /// because `unregister()` throws for an app that isn't registered.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }

    /// Open System Settings at Login Items, for the `.requiresApproval` case.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
