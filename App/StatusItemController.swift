//
//  StatusItemController.swift
//  MacBridge (app) · MacBridge
//
//  The right-click menu and the client status dots on the menu-bar icon.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import Combine
import MacBridgeKit

/// Adds what `MenuBarExtra` can't do on its own: a right-click menu, and coloured
/// status dots under the bridge glyph.
///
/// SwiftUI owns the status item and gives no handle to it, so this finds the
/// button in the status-bar window that SwiftUI created. The dots go in a separate
/// layer-backed subview on top of the icon, so Core Animation can flash them without
/// redrawing the icon on a timer, and they keep moving while the icon is still.
@MainActor
final class StatusItemController: NSObject {

    private let model: AppModel
    private var button: NSStatusBarButton?
    private var indicators: StatusDotsView?
    private var clickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var attachAttempts = 0

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Install the right-click monitor, attach the dots and start following state.
    func start() {
        installClickMonitor()
        attach()

        // objectWillChange fires before the change lands; hopping to the next
        // turn reads the new values. DispatchQueue.main rather than RunLoop.main,
        // which waits out menu tracking, so the dots keep updating while the
        // right-click menu is open. The log is a separate ObservableObject and
        // doesn't republish through the model.
        model.objectWillChange
            .merge(with: model.log.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        // Traffic switches the green dots between breathing and flashing. Only the
        // busy flag, not every animation frame, so this fires twice per burst.
        model.traffic.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        // Reduce Motion can change while the app runs; the dots hold still then.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    /// Remove the event monitor and stop following state, before the app quits.
    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        subscriptions.removeAll()
    }

    // MARK: Finding the button

    /// Find SwiftUI's status-item button and put the dots on it.
    ///
    /// The `MenuBarExtra` scene creates its status item a moment after launch, not
    /// before `applicationDidFinishLaunching`, so this retries briefly until it shows up.
    private func attach() {
        guard let button = Self.findStatusButton() else {
            attachAttempts += 1
            guard attachAttempts <= 20 else {
                BridgeLog.warning("menu-bar button not found; status dots disabled", category: .app)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attach() }
            return
        }

        let dots = StatusDotsView(frame: button.bounds)
        dots.autoresizingMask = [.width, .height]
        button.addSubview(dots)
        self.button = button
        self.indicators = dots
        refresh()
    }

    /// The status-bar windows in this process. MacBridge has exactly one status item,
    /// so whichever button turns up is ours.
    private static func statusBarWindows() -> [NSWindow] {
        NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBarWindow") }
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for window in statusBarWindows() {
            if let button = firstButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = firstButton(in: subview) { return found }
        }
        return nil
    }

    // MARK: Status dots

    private func refresh() {
        // SwiftUI may rebuild its status item, which leaves the dots on a button that
        // is no longer in the menu bar. Find the new button and attach again.
        if let indicators, indicators.window == nil || button?.window == nil {
            indicators.removeFromSuperview()
            self.indicators = nil
            self.button = nil
            attachAttempts = 0
            attach()
            return
        }

        let entries = model.clientHealth
        indicators?.update(
            levels: entries.map(\.health.level),
            busy: model.traffic.isActive,
            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let summary = entries
            .map { "\($0.client.name): \($0.health.reason)" }
            .joined(separator: "\n")
        indicators?.toolTip = summary
        indicators?.setAccessibilityLabel(summary)
    }

    // MARK: Right-click menu

    /// Catch right-clicks (and control-clicks) on the status item before the button
    /// sees them, and show the menu instead of the panel.
    ///
    /// A local monitor sees these because the status-bar window belongs to this
    /// process. Returning nil swallows the event, so the panel doesn't also open.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
            [weak self] event in
            guard let self,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let window = event.window,
                  Self.statusBarWindows().contains(where: { $0 === window }),
                  let view = window.contentView
            else { return event }

            self.showMenu(under: view)
            return nil
        }
    }

    private func showMenu(under view: NSView) {
        let menu = makeMenu()
        // Top-left corner of the menu, just below the item, like a normal status menu.
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "MacBridge — \(AboutView.versionText)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        for entry in model.clientHealth where entry.health.level != .absent {
            let item = NSMenuItem(title: "\(entry.client.name) — \(entry.health.reason)", action: nil, keyEquivalent: "")
            item.image = StatusDotsView.swatch(for: entry.health.level)
            item.isEnabled = false
            menu.addItem(item)
        }
        if menu.items.count > 2 { menu.addItem(.separator()) }

        menu.addItem(item("About MacBridge", #selector(showAbout)))
        menu.addItem(item("Report an Issue…", #selector(reportIssue)))
        menu.addItem(item("Request a Feature…", #selector(requestFeature)))
        menu.addItem(.separator())
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnostics)))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Restart Bridge", #selector(restartBridge)))
        menu.addItem(item("Relaunch App", #selector(relaunchApp)))
        menu.addItem(.separator())
        menu.addItem(item("Quit MacBridge", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showAbout() { AboutWindow.show() }
    @objc private func reportIssue() { NSWorkspace.shared.open(Credits.bugReportURL) }
    @objc private func requestFeature() { NSWorkspace.shared.open(Credits.featureRequestURL) }
    @objc private func copyDiagnostics() { model.copyDiagnostics() }
    @objc private func openLog() { model.openLog() }
    @objc private func restartBridge() { model.restartBridge() }
    @objc private func relaunchApp() { model.relaunchApp() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// The row of status dots under the bridge glyph: Claude Code, then Claude Desktop.
///
/// Green means all is well, yellow means something needs a look, and red means calls
/// can't succeed. How a dot moves says the rest:
///
/// - Green breathes slowly while connected and idle, and flashes quickly while
///   traffic is crossing the bridge, so a working session looks busy at a glance.
/// - Steady green is standby: the client is installed but not connected, which is
///   normal whenever it's closed, set up for MacBridge or not.
/// - Flashing yellow or red, with a soft glow, is a real problem: a failed call,
///   missing permissions or a bridge that's down. It stands out in a crowded menu bar.
///
/// Under Reduce Motion the dots hold still and only their colour speaks. A client
/// that isn't installed gets a faint ring, so the dot positions stay put.
final class StatusDotsView: NSView {

    static let diameter: CGFloat = 4
    static let gap: CGFloat = 4
    private static let pulseKey = "pulse"

    private var dots: [CALayer] = []
    private var levels: [ClientHealth.Level] = []
    private var busy = false
    private var animated = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// Decoration only: clicks go through to the status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show one dot per level.
    ///
    /// - Parameters:
    ///   - busy: Traffic is crossing the bridge, so green dots flash rather than breathe.
    ///   - animated: False under Reduce Motion, which stops every dot moving.
    ///
    /// Layers are rebuilt only when something changed, so frequent refreshes don't
    /// restart the animations.
    func update(levels: [ClientHealth.Level], busy: Bool, animated: Bool) {
        guard levels != self.levels || busy != self.busy || animated != self.animated else { return }
        self.levels = levels
        self.busy = busy
        self.animated = animated
        rebuild()
    }

    override func layout() {
        super.layout()
        positionDots()
    }

    private func rebuild() {
        dots.forEach { $0.removeFromSuperlayer() }
        dots = levels.map { level in
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
            dot.cornerRadius = Self.diameter / 2
            Self.style(dot, for: level)
            if animated, let animation = Self.animation(for: level, busy: busy) {
                dot.add(animation, forKey: Self.pulseKey)
            }
            layer?.addSublayer(dot)
            return dot
        }
        isHidden = levels.allSatisfy { $0 == .absent }
        positionDots()
    }

    /// Centred along the bottom edge, in the gap below the glyph's deck.
    private func positionDots() {
        let count = CGFloat(dots.count)
        let total = count * Self.diameter + max(0, count - 1) * Self.gap
        var x = bounds.midX - total / 2 + Self.diameter / 2
        let y = (isFlipped ? bounds.maxY - 2 - Self.diameter / 2 : bounds.minY + 2 + Self.diameter / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots {
            dot.position = CGPoint(x: x, y: y)
            x += Self.diameter + Self.gap
        }
        CATransaction.commit()
    }

    private static func style(_ dot: CALayer, for level: ClientHealth.Level) {
        switch level {
        case .absent:
            dot.backgroundColor = nil
            dot.borderWidth = 0.75
            dot.borderColor = NSColor.tertiaryLabelColor.cgColor
        case .good, .standby:
            dot.backgroundColor = color(for: level).cgColor
            dot.borderWidth = 0
        case .warning, .problem:
            // A soft glow in the dot's own colour makes it read as lit, not just
            // coloured, at 4pt.
            dot.backgroundColor = color(for: level).cgColor
            dot.borderWidth = 0
            dot.shadowColor = color(for: level).cgColor
            dot.shadowOpacity = 0.9
            // Small enough that the halo isn't cut off by the bottom of the menu bar.
            dot.shadowRadius = 1.5
            dot.shadowOffset = .zero
            // A fixed path, so the shadow isn't re-derived from alpha on every frame
            // of the flash.
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
        }
    }

    /// How a dot moves for its level, or nil for one that holds still.
    ///
    /// The speeds are far enough apart to tell at a glance: a calm green breath about
    /// every three seconds while idle, a quick green flicker while traffic flows, and
    /// a bright yellow or red flash about once a second for a problem. Standby holds
    /// still.
    private static func animation(for level: ClientHealth.Level, busy: Bool) -> CAAnimation? {
        switch level {
        case .absent, .standby:
            return nil
        case .good:
            return busy
                ? fade(to: 0.25, halfPeriod: 0.22)
                : fade(to: 0.3, halfPeriod: 1.5)
        case .warning, .problem:
            return fade(to: 0.1, halfPeriod: 0.45)
        }
    }

    /// Fade from full opacity down to `low` and back, forever.
    private static func fade(to low: Float, halfPeriod: CFTimeInterval) -> CAAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = low
        animation.duration = halfPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survives the app going inactive, which otherwise freezes the animation.
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The fill for a level, shared with the panel's dots so both read the same.
    static func color(for level: ClientHealth.Level) -> NSColor {
        switch level {
        case .good, .standby: return .systemGreen
        case .warning: return .systemYellow
        case .problem: return .systemRed
        case .absent: return .tertiaryLabelColor
        }
    }

    /// A small coloured dot for menu items, matching the menu-bar indicator.
    static func swatch(for level: ClientHealth.Level) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color(for: level).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
