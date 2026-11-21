//
//  SettingsView.swift
//  MacBridge (app) · MacBridge
//
//  The Settings window: safety policy, launch at login and the splash, and diagnostics.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit
import SwiftUI

/// Hosts the Settings tabs in their own AppKit window, for every way of opening it:
/// the panel, the right-click menu and the app delegate's reopen handler.
///
/// Not a SwiftUI `Settings` scene: opening one needs `openSettings`, which only
/// exists once the menu-bar label view has appeared, and on macOS 26 the icon can
/// be hidden in System Settings so it never does. The fallback responder action
/// does nothing on macOS 14 and later, which left a Dock icon and no window.
///
/// MacBridge is an `LSUIElement` (accessory) app, never frontmost by itself, so
/// opening holds a regular activation policy (see ``AppModel/holdRegularPolicy()``)
/// and activates first; the hold is released when the window closes.
@MainActor
final class SettingsOpener: NSObject, NSWindowDelegate {

    private let model: AppModel
    private var window: NSWindow?
    private var policyHold: AppModel.PolicyHold?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Open Settings, or bring the existing window to the front, on the screen the
    /// mouse is on.
    func open() {
        if policyHold == nil { policyHold = model.holdRegularPolicy() }
        let window = self.window ?? makeWindow()
        self.window = window

        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if !window.isVisible, let area = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                          y: area.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        // Toolbar tabs, as in a SwiftUI `Settings` scene and the system apps: an icon
        // and label per tab in the toolbar, and the window titled after the selected tab.
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("Safety", symbol: "lock.shield", SafetySettings(model: model)))
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettings(model: model)))
        tabs.addTabViewItem(tab("Diagnostics", symbol: "stethoscope", DiagnosticsSettings(model: model)))

        let window = NSWindow(contentViewController: tabs)
        // Settle the window at the panes' size now: otherwise it takes that size only
        // when first ordered front, keeping its top-left corner, and `open()` centres
        // it using the wrong frame.
        tabs.view.layoutSubtreeIfNeeded()
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        // Kept, not released: closing then reopening should not rebuild the views.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        return window
    }

    private func tab(_ label: String, symbol: String, _ content: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: SettingsPane(content: content))
        // The tab controller sizes the window from this; the pane's fixed frame sets it.
        controller.sizingOptions = .preferredContentSize
        // The tab controller titles the window from the selected child's `title`, not
        // the item's label; without this the window is "Untitled".
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        if let policyHold { model.releaseRegularPolicy(policyHold) }
        policyHold = nil
    }
}

/// One Settings tab, at the size every tab shares so switching tabs doesn't resize
/// the window.
///
/// A fixed height, not the content's: a Form scrolls, so it has no ideal height of
/// its own, and an AppKit window sized to it collapses to the title bar. A tab with
/// more than fits scrolls inside this.
private struct SettingsPane<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .formStyle(.grouped)
            .frame(width: 460, height: 400)
    }
}

/// What connected clients may do. Read-only covers every write; asking before
/// deleting covers the tools that can't be undone.
private struct SafetySettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.policy.readOnly) {
                    Text("Read-only")
                    Text(model.policy.readOnly
                         ? "Clients can read your calendars and reminders but not change them."
                         : "Clients can add, change and complete items.")
                }
                Toggle(isOn: $model.policy.confirmDestructive) {
                    Text("Ask before deleting")
                    Text("Deleting an event, reminder or list waits for you to allow it.")
                }
                .disabled(model.policy.readOnly)
            }
        }
    }
}

/// Launch at login and the launch splash. The login item's value is what macOS has
/// on record, not a stored preference, so switching it off in System Settings
/// unticks it here.
private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(SplashScreen.enabledKey) private var showSplash = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin != .disabled },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    Text("Open MacBridge at login")
                    Text(LaunchAtLogin.isAvailable
                         ? "Keeps the bridge ready for your AI clients after a restart."
                         : "Available once MacBridge is in your Applications folder.")
                }
                .disabled(!LaunchAtLogin.isAvailable)

                if LaunchAtLogin.isAvailable, model.launchAtLogin == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                    } label: {
                        StatusNote(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                   font: .callout, text: "Switched off in System Settings.")
                    }
                } else if LaunchAtLogin.isAvailable, let error = model.launchAtLoginError {
                    StatusNote(symbol: "xmark.octagon.fill", tint: .red, font: .callout, text: error)
                }
            }
            Section {
                Toggle(isOn: $showSplash) {
                    Text("Show splash screen at launch")
                    Text("Skipped when an AI client starts MacBridge in the background.")
                }
            }
        }
        // The login item can change in System Settings while this window is open.
        .onAppear { model.refreshLaunchAtLogin() }
    }
}

/// The log, the diagnostics report and the restart buttons, for when a client
/// can't reach the bridge. One action per row, label on the left and its button
/// on the right, as in System Settings.
private struct DiagnosticsSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Troubleshooting") {
                LabeledContent {
                    Button("Open Log") { model.openLog() }
                } label: {
                    Text("Activity log")
                    Text("Shows the log file in Finder.")
                }
                LabeledContent {
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                } label: {
                    Text("Diagnostics report")
                    Text("Copies a summary for a bug report.")
                }
                LabeledContent {
                    Button("Refresh") { model.refreshEverything() }
                } label: {
                    Text("Permissions and clients")
                    Text("Checks again after you change them outside MacBridge.")
                }
            }
            Section("Restart") {
                // Restarting the bridge is the cheap fix for a wedged connection;
                // connected clients reconnect on their next call, so it is safe.
                LabeledContent {
                    Button("Restart Bridge") { model.restartBridge() }
                } label: {
                    Text("Bridge")
                    Text("Rebinds the socket. Clients reconnect on their next call.")
                }
                LabeledContent {
                    Button("Relaunch App") { model.relaunchApp() }
                } label: {
                    Text("App")
                    Text("Also picks up Calendar and Reminders permission changes.")
                }
            }
            Section {
                Text(model.shimPath)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } header: {
                Text("Client command")
            } footer: {
                Text("The binary inside this app that AI clients run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
