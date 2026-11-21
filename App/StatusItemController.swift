//
//  StatusItemController.swift
//  MacBridge (app) · MacBridge
//
//  The right-click menu on the menu-bar icon, and the colours of the client status dots.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit

/// Adds what `MenuBarExtra` can't do on its own: a right-click menu.
///
/// SwiftUI owns the status item and gives no handle to it, so right-clicks are caught
/// by a local event monitor instead. The status dots are not added here: they are
/// drawn into the icon image itself (`BridgeRenderer`), so nothing reaches into
/// SwiftUI's windows.
@MainActor
final class StatusItemController: NSObject {

    private let model: AppModel
    private let settings: SettingsOpener
    private var clickMonitor: Any?

    init(model: AppModel, settings: SettingsOpener) {
        self.model = model
        self.settings = settings
        super.init()
    }

    /// Install the right-click monitor.
    func start() {
        installClickMonitor()
    }

    /// Remove the event monitor, before the app quits.
    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Right-click menu

    /// Whether `window` is a menu-bar item's window: a status-level window about as
    /// tall as the menu bar. Public properties only. The panel is a much taller
    /// window, and no other window of ours sits at the status level.
    private static func isStatusItemWindow(_ window: NSWindow) -> Bool {
        window.level == .statusBar && window.frame.height <= 60
    }

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
                  Self.isStatusItemWindow(window),
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

        menu.addItem(.sectionHeader(title: "MacBridge — \(AboutView.versionText)"))

        let installed = model.clientHealth.filter { $0.health.level != .absent }
        for entry in installed {
            let item = NSMenuItem(title: "\(entry.client.name) — \(entry.health.reason)", action: nil, keyEquivalent: "")
            item.image = StatusDots.swatch(for: entry.health.level)
            item.isEnabled = false
            menu.addItem(item)
        }
        if !installed.isEmpty { menu.addItem(.separator()) }

        menu.addItem(item("About MacBridge", #selector(showAbout)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
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
    @objc private func openSettings() { settings.open() }
    @objc private func checkForUpdates() { UpdatePrompt.checkNow() }
    @objc private func reportIssue() { NSWorkspace.shared.open(Credits.bugReportURL) }
    @objc private func requestFeature() { NSWorkspace.shared.open(Credits.featureRequestURL) }
    @objc private func copyDiagnostics() { model.copyDiagnostics() }
    @objc private func openLog() { model.openLog() }
    @objc private func restartBridge() { model.restartBridge() }
    @objc private func relaunchApp() { model.relaunchApp() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// Colours for client health, shared by the panel and the right-click menu so both
/// read the same as the dots drawn into the menu-bar icon (`BridgeRenderer`).
enum StatusDots {

    /// The fill for a level.
    static func color(for level: ClientHealth.Level) -> NSColor {
        switch level {
        case .good, .standby: return .systemGreen
        case .warning: return .systemYellow
        case .problem: return .systemRed
        case .absent: return .tertiaryLabelColor
        }
    }

    /// A small coloured dot for menu items.
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
