//
//  InstallLocation.swift
//  MacBridge (app) · MacBridge
//
//  Offers to move the app into /Applications when it's launched from anywhere else.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit

/// Gets a downloaded copy into /Applications on first launch.
///
/// Where the app lives matters more than usual. macOS ties the Calendar and
/// Reminders grants to the app's location as well as its signature, and every AI
/// client is pointed at the binary inside it. A copy run from Downloads or a mounted
/// disk image works until the user tidies up, then fails with no explanation.
/// So, like most Mac apps distributed outside the App Store, it offers to move
/// itself. `InstallPolicy` decides when; this does the moving.
@MainActor
enum InstallLocation {

    private static let destination = URL(fileURLWithPath: "/Applications/MacBridge.app")
    private static let suppressionKey = "InstallLocation.dontAskToMove"

    /// Ask to move the app if it's running from somewhere other than an Applications
    /// folder.
    ///
    /// - Parameter continueLaunch: Runs when this copy should carry on as normal:
    ///   no move was needed, the user declined, or the move or relaunch failed.
    ///   It doesn't run when the copy in /Applications has taken over and this one
    ///   is quitting.
    static func offerMoveIfNeeded(otherwise continueLaunch: @escaping () -> Void) {
        let bundle = Bundle.main.bundleURL
        let current = bundle.resolvingSymlinksInPath()
        guard InstallPolicy.shouldOfferMove(
            bundlePath: bundle.path,
            resolvedPath: current.path,
            homeDirectory: NSHomeDirectory(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            suppressed: UserDefaults.standard.bool(forKey: suppressionKey)
        ) else {
            continueLaunch()
            return
        }

        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let alert = NSAlert()
        alert.messageText = "Move MacBridge to your Applications folder?"
        alert.informativeText = """
            MacBridge works best from Applications. macOS ties its Calendar and \
            Reminders permissions to where the app lives, and your AI assistants are \
            pointed at that location, so running it from here could stop working later.
            """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressionKey)
        }
        guard response == .alertFirstButtonReturn else {
            continueLaunch()
            return
        }

        do {
            try move(from: current)
        } catch {
            BridgeLog.error("couldn't move to /Applications: \(error)", category: .app)
            showFailure(error, hint: "You can drag MacBridge into Applications in the Finder instead.")
            continueLaunch()
            return
        }
        relaunch(trashingAfterwards: current, otherwise: continueLaunch)
    }

    // MARK: Moving

    /// Put a copy of `source` at /Applications/MacBridge.app, replacing any older copy
    /// only once the new one is fully in place.
    ///
    /// The copy is made beside the destination under a temporary name and swapped in
    /// with two renames on the same volume, so a failure part-way through (a full
    /// disk, no permission) leaves the old copy exactly where it was.
    private static func move(from source: URL) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let incoming = folder.appendingPathComponent(".MacBridge-incoming-\(UUID().uuidString).app")
        let previous = folder.appendingPathComponent("MacBridge (previous version).app")

        // Copy first: if that fails (a full disk, a non-admin user), any copy already
        // running from Applications is left running.
        try fileManager.copyItem(at: source, to: incoming)
        removeQuarantine(from: incoming)

        // What was at the destination, so a failed swap puts exactly that back.
        var linkTarget: String?
        var movedAside = false
        do {
            try quitOtherCopies()
            if isSymlink(destination) {
                // A link the user made: replace the link, never the copy it points to.
                linkTarget = try fileManager.destinationOfSymbolicLink(atPath: destination.path)
                try fileManager.removeItem(at: destination)
            } else if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: previous)
                try fileManager.moveItem(at: destination, to: previous)
                movedAside = true
            }
            do {
                try fileManager.moveItem(at: incoming, to: destination)
            } catch {
                if movedAside {
                    try? fileManager.moveItem(at: previous, to: destination)
                } else if let linkTarget {
                    try? fileManager.createSymbolicLink(atPath: destination.path,
                                                        withDestinationPath: linkTarget)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }

        if movedAside {
            try? fileManager.trashItem(at: previous, resultingItemURL: nil)
        }
        BridgeLog.info("moved to /Applications from \(source.path)", category: .app)
    }

    /// Quit every other running MacBridge, e.g. an older version when updating to a
    /// new download, and wait for them to be gone.
    ///
    /// Every copy, not only one at the destination: one launched through a symlink or
    /// from another folder can be serving the same socket. Waiting matters too: an old
    /// copy that quits after the new one starts would delete the new one's socket on
    /// its way out.
    private static func quitOtherCopies() throws {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != .current }
        guard !older.isEmpty else { return }

        older.forEach { $0.terminate() }
        if waitUntilTerminated(older, seconds: 5) { return }
        older.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        guard waitUntilTerminated(older, seconds: 2) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Another copy of MacBridge is running and didn't quit.",
            ])
        }
    }

    private static func waitUntilTerminated(_ apps: [NSRunningApplication], seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while apps.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// Drop the download's quarantine flag from the copy.
    ///
    /// macOS only stops running a quarantined app from a temporary, translocated path
    /// when the user moves it in the Finder. A copy the app makes itself keeps the
    /// flag, and would relaunch translocated: offering to move again, and handing that
    /// temporary path to any client the user then connects. The user has already
    /// approved this notarized app by opening it, so clearing the flag is safe.
    private static func removeQuarantine(from url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                BridgeLog.warning("xattr exited \(process.terminationStatus) clearing quarantine on \(url.path)",
                                  category: .app)
            }
        } catch {
            BridgeLog.warning("couldn't clear quarantine on \(url.path): \(error)", category: .app)
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    // MARK: Relaunching

    /// Start the copy in /Applications and quit this one. If it won't start, say so
    /// and keep this copy running rather than vanishing from the menu bar.
    ///
    /// The downloaded original goes to the Trash only once the new copy is running:
    /// if the relaunch fails, this copy carries on, and must still be where it was.
    private static func relaunch(trashingAfterwards source: URL, otherwise continueLaunch: @escaping () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard let error else {
                    if InstallPolicy.mayTrashSource(at: source.path, destination: destination.path) {
                        try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
                    }
                    NSApp.terminate(nil)
                    return
                }
                BridgeLog.error("couldn't relaunch from /Applications: \(error)", category: .app)
                showFailure(error, hint: "MacBridge was copied to Applications. Open it from there.")
                continueLaunch()
            }
        }
    }

    private static func showFailure(_ error: Error, hint: String) {
        let alert = NSAlert(error: error)
        alert.informativeText = "\(error.localizedDescription)\n\n\(hint)"
        alert.runModal()
    }
}
