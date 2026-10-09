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
/// button in the status-bar window that SwiftUI created. The menu-bar icon stays a
/// template image, so macOS keeps tinting it for light, dark and coloured
/// menu bars, and the dots go in a separate layer-backed subview on top. Template
/// images can't carry colour, and Core Animation pulses the dots without
/// redrawing the icon on a timer.
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

        // Reduce Motion can change while the app runs; the dots stop pulsing then.
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
            pulsing: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    @objc private func copyDiagnostics() { model.copyDiagnostics() }
    @objc private func openLog() { model.openLog() }
    @objc private func restartBridge() { model.restartBridge() }
    @objc private func relaunchApp() { model.relaunchApp() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// The row of status dots under the bridge glyph: Claude Code, then Claude Desktop.
///
/// Green means connected and working, yellow means something needs a look, and red
/// means calls can't succeed. The dots breathe slowly, unless Reduce Motion is on.
/// A client that isn't installed gets a faint ring, so the dot positions stay put.
final class StatusDotsView: NSView {

    static let diameter: CGFloat = 4
    static let gap: CGFloat = 4
    private static let pulseKey = "pulse"

    private var dots: [CALayer] = []
    private var levels: [ClientHealth.Level] = []
    private var pulsing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// Decoration only: clicks go through to the status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show one dot per level. Layers are rebuilt only when something changed, so
    /// frequent refreshes don't restart the pulse.
    func update(levels: [ClientHealth.Level], pulsing: Bool) {
        guard levels != self.levels || pulsing != self.pulsing else { return }
        self.levels = levels
        self.pulsing = pulsing
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
            if pulsing && level != .absent {
                dot.add(Self.pulseAnimation(), forKey: Self.pulseKey)
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
        default:
            dot.backgroundColor = color(for: level).cgColor
            dot.borderWidth = 0
        }
    }

    /// A slow fade in and out, about one breath every three seconds. It's slow
    /// enough that a green dot reads as alive, not as an alert.
    private static func pulseAnimation() -> CAAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.3
        animation.duration = 1.5
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
        case .good: return .systemGreen
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
