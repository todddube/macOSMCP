//
//  SettingsView.swift
//  MacBridge (app) · MacBridge
//
//  The Settings window: safety policy, launch at login and diagnostics.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit
import SwiftUI

/// Hosts ``SettingsView`` in its own AppKit window, for every way of opening it:
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
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "MacBridge Settings"
        window.styleMask = [.titled, .closable]
        // Kept, not released: closing then reopening should not rebuild the view.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let policyHold { model.releaseRegularPolicy(policyHold) }
        policyHold = nil
    }
}

/// Settings, in tabs: what clients may do, startup, and the maintenance tools.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            SafetySettings(model: model)
                .tabItem { Label("Safety", systemImage: "lock.shield") }
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsSettings(model: model)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .formStyle(.grouped)
        // A fixed height, not the content's: a Form scrolls, so it has no ideal height
        // of its own, and an AppKit window sized to it collapses to the title bar.
        // A tab with more than fits scrolls inside this.
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
                Toggle("Read-only", isOn: $model.policy.readOnly)
                if model.policy.readOnly {
                    StatusNote(symbol: "lock.fill", tint: .orange,
                               text: "Clients can read your calendars and reminders but not change them.")
                } else {
                    Text("Clients can add, change and complete items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Ask before deleting", isOn: $model.policy.confirmDestructive)
                    .disabled(model.policy.readOnly)
                Text("Deleting an event, reminder or list waits for you to allow it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Launch at login. Its value is what macOS has on record, not a stored preference,
/// so switching it off in System Settings unticks it here.
private struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open MacBridge at login", isOn: Binding(
                    get: { model.launchAtLogin != .disabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .disabled(!LaunchAtLogin.isAvailable)

                if !LaunchAtLogin.isAvailable {
                    Text("Available once MacBridge is in your Applications folder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.launchAtLogin == .requiresApproval {
                    HStack(spacing: 6) {
                        StatusNote(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                   text: "Switched off in System Settings.")
                        Spacer()
                        Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                    }
                } else if let error = model.launchAtLoginError {
                    StatusNote(symbol: "xmark.octagon.fill", tint: .red, text: error)
                } else {
                    Text("Keeps the bridge ready for your AI clients after a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // The login item can change in System Settings while this window is open.
        .onAppear { model.refreshLaunchAtLogin() }
    }
}

/// The log, the diagnostics report and the restart buttons, for when a client
/// can't reach the bridge.
private struct DiagnosticsSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Logs") {
                HStack(spacing: 8) {
                    Button("Open Log") { model.openLog() }
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                    Button("Refresh") { model.refreshEverything() }
                }
            }
            Section("Restart") {
                HStack(spacing: 8) {
                    // Restarting the bridge is the cheap fix for a wedged connection;
                    // connected clients reconnect on their next call, so it is safe.
                    Button("Restart Bridge") { model.restartBridge() }
                    Button("Relaunch App") { model.relaunchApp() }
                }
                Text("Restart Bridge rebinds the socket. Relaunch also picks up permission changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("This app's binary, which clients invoke") {
                Text(model.shimPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .formStyle(.grouped)
    }
}
