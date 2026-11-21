//
//  MacBridgeApp.swift
//  MacBridge (app) · MacBridge
//
//  The MenuBarExtra scene, app delegate and menu-bar icon.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit
import SwiftUI

/// MacBridge — a menu-bar-only app that serves macOS Calendar and Reminders to AI
/// clients over MCP.
///
/// `LSUIElement` is set in Info.plist, so there is no Dock icon and no window: the
/// menu bar is the whole interface. The bridge server starts and stops with the
/// app, and the `macbridge` shim inside this bundle launches the app on demand
/// when a client connects cold.
///
/// Not `@main`: App/main.swift is the entry point, because this binary is also the
/// CLI and has to decide which of the two it is being run as.
struct MacBridgeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                model: delegate.model, log: delegate.model.log, traffic: delegate.model.traffic,
                settings: delegate.settings
            )
        } label: {
            MenuBarLabel(model: delegate.model, log: delegate.model.log, traffic: delegate.model.traffic)
        }
        // .window rather than the default .menu: the panel shows permissions,
        // connected clients and a scrolling activity list, none of which belong in
        // a plain menu.
        .menuBarExtraStyle(.window)
        // Settings is an AppKit window (`SettingsOpener`), not a `Settings` scene:
        // a scene can only be opened once this label has appeared, and it may never.
    }
}

/// Starts the bridge at launch and shuts it down cleanly on quit.
///
/// A delegate rather than work in `App.init` because the server must come up at
/// launch — not when the menu is first opened — and because the socket needs
/// removing on the way out so the next launch does not find a stale file.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = AppModel()
    private(set) lazy var settings = SettingsOpener(model: model)
    private lazy var statusItem = StatusItemController(model: model, settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A copy run from Downloads or a disk image offers to move itself first. If
        // it moves, the copy in /Applications takes over and this one quits without
        // starting; otherwise launch carries on here.
        InstallLocation.offerMoveIfNeeded(
            whileAsking: { [self] in model.start() },
            beforeMove: { [self] in model.stop() },
            otherwise: { [self] in
                model.start()
                statusItem.start()
            }
        )
    }

    /// Opening MacBridge again (Finder, Spotlight, the Dock) shows Settings. On
    /// macOS 26 and later the menu-bar icon can be hidden in System Settings, and
    /// this is then the only way to reach any UI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem.stop()
        model.stop()
    }
}

/// The menu-bar icon, in its own view so it can observe and react to state.
///
/// Custom artwork rather than an SF Symbol: no stock symbol says "bridge", and the
/// glyph should match the app icon. It is drawn by `BridgeRenderer`. While the bridge
/// is quiet it is a template image, so the system tints it like any other menu-bar
/// icon; cars crossing, an alert or a client in trouble switch to a colour image.
/// While calls are in flight the frames animate cars crossing the span; once the
/// bridge is quiet the clock stops and nothing redraws.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    /// Observed separately for the same reason as `MenuContent.log`: a nested
    /// ObservableObject does not republish through its parent. The client dots
    /// depend on which clients are connected.
    @ObservedObject var log: ActivityLog
    @ObservedObject var traffic: BridgeTraffic

    var body: some View {
        let health = model.clientHealth
        let image = traffic.menuBarImage(alert: isAlert, dots: health.map(\.health.level))
        // Labelled here because an NSImage-backed Image has no name for VoiceOver
        // to read, and MenuBarExtra(content:label:) has no title of its own.
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .accessibilityLabel(isAlert ? "MacBridge, needs attention" : "MacBridge")
            .accessibilityValue(health.filter { $0.health.level != .absent }
                .map { "\($0.client.name): \($0.health.reason)" }.joined(separator: ". "))
    }

    /// The broken-span variant distinguishes "up but unusable" from "up and
    /// working" without opening the panel. Permissions are what actually block a
    /// call, so they decide the icon.
    private var isAlert: Bool {
        switch model.state {
        case .listening:
            return !EventKitDomain.allCases.allSatisfy { model.hasAccess($0) }
        case .stopped, .failed:
            return true
        }
    }
}
