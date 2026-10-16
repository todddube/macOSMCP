//
//  InstallPolicy.swift
//  MacBridgeKit · MacBridge
//
//  Decides when to offer moving the app to /Applications, and what may be tidied up.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// The rules behind the app's "Move to Applications?" offer, kept free of AppKit so
/// every path case is testable. The app's `InstallLocation` does the moving.
public enum InstallPolicy {

    /// Whether to offer the move for a bundle at `bundlePath`.
    ///
    /// Both the path as launched and the path with symlinks resolved are checked, so
    /// a `/Applications/MacBridge.app` symlink to a copy elsewhere counts as
    /// installed: the user put it there on purpose.
    ///
    /// - Parameters:
    ///   - bundlePath: `Bundle.main.bundlePath`, unresolved.
    ///   - resolvedPath: The same with symlinks resolved.
    ///   - homeDirectory: For `~/Applications`, which counts as installed too.
    ///   - bundleIdentifier: Debug builds (`.debug`) run from DerivedData on purpose.
    ///   - suppressed: The user ticked "Don't ask again".
    public static func shouldOfferMove(
        bundlePath: String,
        resolvedPath: String,
        homeDirectory: String,
        bundleIdentifier: String,
        suppressed: Bool
    ) -> Bool {
        guard !suppressed, !bundleIdentifier.hasSuffix(".debug") else { return false }
        return !isInstalled(bundlePath: bundlePath, resolvedPath: resolvedPath, homeDirectory: homeDirectory)
    }

    /// Whether a bundle lives in `/Applications` or `~/Applications`, by either its
    /// launched or its symlink-resolved path.
    ///
    /// Also gates "Open at login": a login item points at a location, so it's only
    /// offered for a copy that will stay where it is.
    public static func isInstalled(bundlePath: String, resolvedPath: String, homeDirectory: String) -> Bool {
        let folders = ["/Applications/", homeDirectory + "/Applications/"]
        return [bundlePath, resolvedPath].contains { path in
            folders.contains { path.hasPrefix($0) }
        }
    }

    /// Whether the original may go to the Trash once copied into /Applications.
    ///
    /// Only a plain copy in a writable folder, usually Downloads. A disk image is
    /// read-only, and a translocated copy is a temporary view of the real download,
    /// whose location isn't known.
    public static func mayTrashSource(at path: String, destination: String) -> Bool {
        !path.contains("/AppTranslocation/")
            && !path.hasPrefix("/Volumes/")
            && path != destination
    }
}
