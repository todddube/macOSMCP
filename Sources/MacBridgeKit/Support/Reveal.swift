//
//  Reveal.swift
//  MacBridgeKit · MacBridge
//
//  Opens a URL in the owning macOS app, without linking AppKit.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import Foundation

/// Opens a URL in the owning macOS app.
///
/// Uses `/usr/bin/open` rather than `NSWorkspace` to keep MacBridgeKit free of
/// AppKit, so the kit stays linkable and testable from a plain CLI process.
enum Reveal {

    /// Runs `open <url>` and waits for it; throws if it can't launch or exits non-zero.
    static func open(_ url: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw MacBridgeError.saveFailed(underlying: "could not launch /usr/bin/open: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MacBridgeError.saveFailed(
                underlying: "macOS could not open '\(url)' (exit \(process.terminationStatus))"
            )
        }
    }

    /// Deep link that reveals an event in Calendar.app.
    static func calendarEventURL(identifier: String) -> String {
        "ical://ekevent/\(identifier)?method=show&options=more"
    }

    /// Deep link that reveals a reminder in Reminders.app.
    static func reminderURL(identifier: String) -> String {
        "x-apple-reminderkit://REMCDReminder/\(identifier)"
    }
}
