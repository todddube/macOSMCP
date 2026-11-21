//
//  ConfirmationPrompt.swift
//  MacBridge (app) · MacBridge
//
//  Asks the user before a client deletes anything or changes how an event repeats.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit

/// The alert that asks the user before a client deletes anything or changes how an
/// event repeats (`calendar_update_event` on a recurring event).
///
/// Not modal. A nested modal run loop entered from a main-actor job does not drain
/// the main dispatch queue, so every other main-actor hop (all tool calls pass
/// through the policy check there, as do the event stream and SwiftUI) would stall
/// until the alert was answered. Instead the panel is shown and the caller awaits a
/// continuation that the buttons, Escape or a timer resolve, exactly once.
///
/// Alerts are shown one at a time, the rest queued in arrival order. The deadline
/// is set when the call *arrives* (before it hops to the main actor or queues), so
/// a delete queued behind another gets only what is left of its ``budget`` and is
/// declined as timed out when that is gone, rather than being approvable after the
/// client's 120-second read timeout has already given up on it.
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

    /// One call waiting on, or showing, an alert. Resolved at most once.
    private final class Request {
        let client: ClientIdentity
        let tool: String
        let target: String?
        let deadline: Date
        var continuation: CheckedContinuation<Outcome, Never>?
        var panel: PromptPanel?
        var timers: [Timer] = []

        init(client: ClientIdentity, tool: String, target: String?, deadline: Date) {
            self.client = client
            self.tool = tool
            self.target = target
            self.deadline = deadline
        }
    }

    /// Waiting for the visible alert to be answered, oldest first.
    private static var queue: [Request] = []
    /// The request whose alert is on screen.
    private static var current: Request?

    /// Ask whether `client` may run `tool` on `target`, returning once the user
    /// answers or time runs out. The main actor stays free while this waits.
    ///
    /// - Parameters:
    ///   - target: what would be removed, in words, when it could be looked up; the
    ///     alert still asks without it.
    ///   - deadline: when the call stops waiting, fixed when the call arrived; the
    ///     alert closes then, and isn't shown at all if too little time remains.
    static func ask(
        client: ClientIdentity, tool: String, target: String?, deadline: Date
    ) async -> Outcome {
        guard deadline.timeIntervalSinceNow >= minimumShowTime else { return .timedOut }
        let request = Request(client: client, tool: tool, target: target, deadline: deadline)
        return await withCheckedContinuation { continuation in
            request.continuation = continuation
            // Still queued when the deadline passes: give up without waiting for the
            // alert ahead to finish.
            addTimer(to: request, after: deadline.timeIntervalSinceNow) { complete(request, .timedOut) }
            queue.append(request)
            presentNext()
        }
    }

    private static func addTimer(
        to request: Request, after interval: TimeInterval, repeats: Bool = false,
        _ fire: @escaping @MainActor () -> Void
    ) {
        let timer = Timer(timeInterval: max(0, interval), repeats: repeats) { _ in
            MainActor.assumeIsolated { fire() }
        }
        // .common, so it also fires while a menu or a tracking loop is running.
        RunLoop.main.add(timer, forMode: .common)
        request.timers.append(timer)
    }

    /// Show the next queued alert, if none is up.
    private static func presentNext() {
        guard current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        let available = min(timeout, request.deadline.timeIntervalSinceNow)
        guard available >= minimumShowTime else {
            complete(request, .timedOut)
            return
        }
        current = request
        let end = Date().addingTimeInterval(available)

        var details: [String] = []
        if let target = request.target { details.append("It would delete \(target).") }
        details.append("This can't be undone.")

        // Who is asking, from what the app worked out rather than what the client
        // said about itself. The pid is the macbridge shim's, so it is not shown.
        var source = request.client.executablePath
            .map { "Application: " + ($0 as NSString).abbreviatingWithTildeInPath }
            ?? "Application: unknown"
        if let claimed = request.client.claimedName { source += "\n(reported itself as '\(claimed)')" }

        let countdown = NSTextField(labelWithString: "")
        countdown.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countdown.textColor = .secondaryLabelColor
        func updateCountdown() {
            let left = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
            countdown.stringValue = "If you don't answer, MacBridge declines in \(left) second\(left == 1 ? "" : "s")."
        }
        updateCountdown()

        let panel = PromptPanel(
            title: "\(request.client.name) wants to \(action(for: request.tool))",
            details: details.joined(separator: "\n\n"),
            source: source,
            countdown: countdown,
            confirmTitle: request.tool == "calendar_update_event" ? "Change Repeat" : "Delete"
        )
        panel.onAnswer = { [unowned request] approved in
            complete(request, approved ? .approved : .declined)
        }
        request.panel = panel
        addTimer(to: request, after: available) { complete(request, .timedOut) }
        addTimer(to: request, after: 1, repeats: true) { updateCountdown() }

        // Floating and non-activating: activation is only a request on macOS 14+ and
        // an accessory app often doesn't get it, which is how an alert used to open
        // behind the app the user was typing in. This is shown regardless and leaves
        // that app frontmost; making it key lets Escape and Tab reach it.
        panel.place()
        panel.makeKey()
    }

    /// Resolve `request` once: tear down its alert and timers, resume its caller,
    /// then show whatever is queued next. Later calls for the same request (a timer
    /// racing a button) do nothing.
    private static func complete(_ request: Request, _ outcome: Outcome) {
        guard let continuation = request.continuation else { return }
        request.continuation = nil
        request.timers.forEach { $0.invalidate() }
        request.timers = []
        request.panel?.onAnswer = nil
        request.panel?.orderOut(nil)
        request.panel = nil
        queue.removeAll { $0 === request }
        let wasCurrent = current === request
        if wasCurrent { current = nil }
        continuation.resume(returning: outcome)
        // Also when a skipped (never shown) request completes: whatever is queued
        // behind it must not be stranded. A no-op while an alert is still up.
        presentNext()
    }

    /// Decline everything queued and showing, when the bridge stops: the
    /// connections these calls arrived on are closed, so nobody is waiting.
    static func cancelAll() {
        let all = (current.map { [$0] } ?? []) + queue
        for request in all { complete(request, .declined) }
    }

    /// "delete a calendar event", for the alert's title.
    private static func action(for tool: String) -> String {
        switch tool {
        case "calendar_cancel_event": return "delete a calendar event"
        case "reminders_delete_reminder": return "delete a reminder"
        case "reminders_delete_list": return "delete a reminder list"
        case "calendar_update_event": return "change how an event repeats"
        default: return "run \(tool)"
        }
    }
}

/// The alert's window: a floating panel that appears above other apps on the
/// screen the user is on, without making MacBridge the active app.
///
/// Per the HIG for a destructive confirmation, neither button is the Return
/// default (a stray keystroke from whatever the user was typing must do nothing),
/// Escape declines, and the destructive button sits on the trailing side. Both
/// buttons are in the key-view loop, so Tab (full keyboard access) reaches them.
@MainActor
private final class PromptPanel: NSPanel {

    /// Called with the user's answer; the owner resolves the request once.
    var onAnswer: ((Bool) -> Void)?

    init(title: String, details: String, source: String, countdown: NSTextField, confirmTitle: String) {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .modalPanel
        hidesOnDeactivate = false
        isRestorable = false
        // Follow the user to whichever Space (or full-screen app) they're in.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.setAccessibilityElement(false)

        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let body = NSTextField(wrappingLabelWithString: details)
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        let origin = NSTextField(wrappingLabelWithString: source)
        origin.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        origin.textColor = .secondaryLabelColor
        origin.lineBreakMode = .byCharWrapping
        for label in [heading, body, origin, countdown] { label.preferredMaxLayoutWidth = 320 }

        // Cancel is not the Return default, only Escape; Delete has no key equivalent.
        let decline = NSButton(title: "Cancel", target: self, action: #selector(decline(_:)))
        decline.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: confirmTitle, target: self, action: #selector(confirm(_:)))
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""

        let buttons = NSStackView(views: [decline, confirm])
        buttons.spacing = 12
        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.distribution = .fill

        let text = NSStackView(views: [heading, body, origin, countdown])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 16

        let root = NSStackView(views: [top, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 30, left: 24, bottom: 20, right: 24)
        buttonRow.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        contentView = root
        autorecalculatesKeyViewLoop = true
        setContentSize(root.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    /// Escape, however focus is arranged.
    override func cancelOperation(_ sender: Any?) { finish(approved: false) }

    @objc private func decline(_ sender: Any?) { finish(approved: false) }
    @objc private func confirm(_ sender: Any?) { finish(approved: true) }

    private func finish(approved: Bool) { onAnswer?(approved) }

    /// Centre on the screen the mouse is on (where the user is looking), and show
    /// the panel even though the app isn't active.
    func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
        } else {
            center()
        }
        orderFrontRegardless()
    }
}
