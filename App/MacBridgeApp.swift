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
            MenuContent(model: delegate.model, log: delegate.model.log, traffic: delegate.model.traffic)
        } label: {
            MenuBarLabel(model: delegate.model, traffic: delegate.model.traffic)
        }
        // .window rather than the default .menu: the panel shows permissions,
        // connected clients and a scrolling activity list, none of which belong in
        // a plain menu.
        .menuBarExtraStyle(.window)
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
    private lazy var statusItem = StatusItemController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        statusItem.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem.stop()
        model.stop()
    }
}

/// The menu-bar icon, in its own view so it can observe and react to state.
///
/// Custom artwork rather than an SF Symbol: no stock symbol says "bridge", and the
/// glyph should match the app icon. Both images are template assets, so macOS tints
/// them for light, dark and highlighted menu bars.
///
/// While calls are in flight the static asset gives way to frames drawn by
/// `BridgeTraffic` — cars crossing the span — and returns once the bridge is quiet.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    /// Observed separately for the same reason as `MenuContent.log`: a nested
    /// ObservableObject does not republish through its parent.
    @ObservedObject var traffic: BridgeTraffic

    var body: some View {
        if traffic.isActive {
            Image(nsImage: traffic.menuBarImage(alert: imageName == "MenuBarBridgeAlert"))
        } else {
            Image(imageName)
        }
    }

    private var imageName: String {
        switch model.state {
        case .listening:
            // The broken-span variant distinguishes "up but unusable" from "up and
            // working" without opening the panel. Permissions are what actually
            // block a call, so they decide the icon.
            let granted = EventKitDomain.allCases.allSatisfy { model.hasAccess($0) }
            return granted ? "MenuBarBridge" : "MenuBarBridgeAlert"
        case .stopped, .failed:
            return "MenuBarBridgeAlert"
        }
    }
}
