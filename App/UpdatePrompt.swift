//
//  UpdatePrompt.swift
//  MacBridge (app) · MacBridge
//
//  Check for Updates…: asks GitHub and says what it found.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit

/// Check for Updates…, from the right-click menu and the About window.
///
/// Only on request: see ``UpdateCheck`` for why there is no automatic check.
/// Downloading stays a click on the release page, since a release is a signed
/// DMG the user installs themselves.
@MainActor
enum UpdatePrompt {

    /// Set while a check is running, so a second click doesn't start another.
    private static var isChecking = false

    /// Check, then show the answer in an alert.
    static func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            defer { isChecking = false }
            let outcome: Result<UpdateCheck.Result, Error>
            do {
                outcome = .success(try await UpdateCheck.run())
            } catch {
                outcome = .failure(error)
            }
            show(outcome)
        }
    }

    private static func show(_ outcome: Result<UpdateCheck.Result, Error>) {
        let alert = NSAlert()
        switch outcome {
        case .success(.available(let version, let page)):
            alert.messageText = "MacBridge \(version) is available"
            alert.informativeText = "You have \(MacBridge.version). The release page has the download and what changed."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(page)
            }
            return
        case .success(.upToDate):
            alert.messageText = "MacBridge is up to date"
            alert.informativeText = "\(MacBridge.version) is the newest version."
        case .success(.noReleases):
            alert.messageText = "No releases yet"
            alert.informativeText = "Nothing has been published on GitHub yet, so there is nothing newer than \(MacBridge.version)."
        case .failure(let error):
            BridgeLog.warning("update check failed: \(error.localizedDescription)", category: .app)
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "\(error.localizedDescription) Releases are also listed on GitHub."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Releases")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(Credits.releasesURL)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
