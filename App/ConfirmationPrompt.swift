//
//  ConfirmationPrompt.swift
//  MacBridge (app) · MacBridge
//
//  The alert that asks the user before a client deletes anything.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit

/// The alert that asks the user before a client deletes anything.
///
/// Modal, because the call is waiting on the answer and nothing else in the app
/// needs the user meanwhile. It gives up at a deadline so a client is never left
/// hanging on an alert nobody is looking at.
///
/// The deadline is set when the call *arrives*, not when its alert appears:
/// alerts are shown one at a time, and a delete queued behind another would
/// otherwise wait out the first alert and then a full one of its own, past the
/// bridge's 120-second read timeout — so the client would have given up while the
/// alert could still be approved. ``budget`` keeps every outcome inside that.
@MainActor
enum ConfirmationPrompt {

    /// How the alert ended. A timeout is kept apart from Don't Allow so the model
    /// is told to have the user watch for the prompt rather than not to retry.
    enum Outcome: Equatable {
        case approved
        case declined
        case timedOut
    }

    /// Longest any one alert stays up.
    static let timeout: TimeInterval = 60
    /// Longest a call may wait in total, queueing included; well under the
    /// bridge's 120-second read timeout.
    static let budget: TimeInterval = 90
    /// An alert with less time than this left is skipped as timed out: nobody can
    /// read it and decide in a couple of seconds.
    static let minimumShowTime: TimeInterval = 5

    /// Ask whether `client` may run `tool` on `target`.
    ///
    /// - Parameters:
    ///   - target: what would be removed, in words, when it could be looked up; the
    ///     alert still asks without it.
    ///   - deadline: when the call stops waiting; the alert closes then, and isn't
    ///     shown at all if too little time remains.
    static func ask(client: String, tool: String, target: String?, deadline: Date) -> Outcome {
        let available = min(timeout, deadline.timeIntervalSinceNow)
        guard available >= minimumShowTime else { return .timedOut }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(client) wants to \(action(for: tool))"

        var details: [String] = []
        if let target { details.append("It would delete \(target).") }
        details.append("This can't be undone. If you don't answer, MacBridge declines in \(Int(available)) seconds.")
        alert.informativeText = details.joined(separator: "\n\n")

        // Don't Allow is the default button: an alert that appears while someone is
        // typing elsewhere must not delete anything on a stray Return.
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let decline = alert.addButton(withTitle: "Don't Allow")
        decline.keyEquivalent = "\r"

        // A menu-bar app is never frontmost on its own, so without this the alert
        // opens behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating

        var timedOut = false
        let timer = Timer(timeInterval: available, repeats: false) { _ in
            MainActor.assumeIsolated {
                timedOut = true
                NSApp.abortModal()
            }
        }
        // The modal loop runs in its own mode; a default-mode timer would never fire.
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()

        if timedOut { return .timedOut }
        return response == .alertFirstButtonReturn ? .approved : .declined
    }

    /// "delete a calendar event", for the alert's title.
    private static func action(for tool: String) -> String {
        switch tool {
        case "calendar_cancel_event": return "delete a calendar event"
        case "reminders_delete_reminder": return "delete a reminder"
        case "reminders_delete_list": return "delete a reminder list"
        default: return "run \(tool)"
        }
    }
}
