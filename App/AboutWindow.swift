//
//  AboutWindow.swift
//  MacBridge (app) · MacBridge
//
//  The About window: what MacBridge is for, who made it, and where the code lives.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit
import SwiftUI

/// Shows the single About window, from the panel or the right-click menu.
///
/// An AppKit window rather than a SwiftUI `Window` scene: this is a menu-bar-only
/// app, and a scene window opened from a `MenuBarExtra` can't be reached from the
/// AppKit right-click menu. One controller serves both, and reopening it brings the
/// existing window forward instead of stacking copies.
@MainActor
enum AboutWindow {

    private static var window: NSWindow?

    /// Open the About window, or bring the existing one to the front.
    static func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // An accessory app is never frontmost by itself, so without activating, the
        // window would open behind whatever the user is working in.
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About MacBridge"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Kept, not released: closing then reopening should not rebuild the view.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        return window
    }
}

/// The About window's content.
struct AboutView: View {

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("MacBridge")
                    .font(.title.weight(.semibold))
                Text(Self.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("""
                MacBridge connects AI assistants, such as Claude Code and Claude \
                Desktop, to your Mac's Calendar and Reminders through the Model \
                Context Protocol. You grant Calendar and Reminders access once, to \
                this app, and every assistant goes through it. The menu bar shows \
                what each one is doing.
                """)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 8) {
                Text("Created by \(Credits.author)")
                    .font(.callout.weight(.medium))
                linkRow(symbol: "person.crop.circle", title: "GitHub", url: Credits.authorURL)
                linkRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Repository",
                        url: Credits.repositoryURL)
                linkRow(symbol: "checkmark.seal", title: "License", url: Credits.licenseURL, label: Credits.license)
                linkRow(symbol: "exclamationmark.bubble", title: "Feedback", url: Credits.issuesURL,
                        label: "Issues & feature requests")
            }

            HStack(spacing: 8) {
                Button("Report an Issue…") { NSWorkspace.shared.open(Credits.bugReportURL) }
                Button("Request a Feature…") { NSWorkspace.shared.open(Credits.featureRequestURL) }
            }
            .controlSize(.small)

            Divider()

            acknowledgements

            VStack(spacing: 2) {
                Text("\(Credits.copyright). Free and open source under the \(Credits.license).")
                Text("Not affiliated with Apple or Anthropic.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 420)
    }

    /// A labelled, clickable link that shows its full address, so the URL can be
    /// read (and selected) as well as followed.
    /// - Parameter label: Shown instead of the address when the address is too long
    ///   to read at a glance; the full URL is still in the tooltip.
    private func linkRow(symbol: String, title: String, url: URL, label: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.secondary)
            Link(label ?? url.absoluteString.replacingOccurrences(of: "https://", with: ""), destination: url)
                .help(url.absoluteString)
        }
        .font(.callout)
    }

    /// Marketing version, plus the build number when it says something extra.
    /// Shared with the right-click menu so both always show the same thing.
    static var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty, build != MacBridge.version else {
            return "Version \(MacBridge.version)"
        }
        return "Version \(MacBridge.version) (\(build))"
    }

    /// The open-source components MacBridge is built on, each linked to its source,
    /// and a button that opens their full license texts.
    private var acknowledgements: some View {
        VStack(spacing: 6) {
            Text("Built with")
                .font(.callout.weight(.medium))
            ForEach(Credits.components) { component in
                // Name, then author and license as wrapping text, so a long license
                // ("MIT / Apache-2.0") is never truncated in the very place it is credited.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Link(component.name, destination: component.url)
                        .help(component.url.absoluteString)
                    Text("· \(component.author) · \(component.license)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            Button("Third-Party Licenses…", action: Self.openThirdPartyNotices)
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    /// Opens a copy of the bundled THIRD_PARTY_NOTICES.md in TextEdit.
    ///
    /// The bundled copy rather than the web page: the licenses must travel with the
    /// binary, and this works offline. It is copied to a temporary folder first because
    /// TextEdit opens files editable and autosaves in place; opened directly, a stray
    /// keystroke would try to write inside the signed app bundle. TextEdit is named
    /// because a `.md` file's default app is often Xcode or nothing at all. The
    /// repository copy is the fallback for a build that somehow lacks the resource.
    private static func openThirdPartyNotices() {
        guard let bundled = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
            NSWorkspace.shared.open(Credits.repositoryURL.appending(path: "blob/main/THIRD_PARTY_NOTICES.md"))
            return
        }
        let copy = FileManager.default.temporaryDirectory.appending(path: "MacBridge Third-Party Notices.md")
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: bundled, to: copy)
        } catch {
            BridgeLog.error("Couldn't copy the third-party notices: \(error)", category: .app)
            NSWorkspace.shared.open(Credits.repositoryURL.appending(path: "blob/main/THIRD_PARTY_NOTICES.md"))
            return
        }
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(copy)
            return
        }
        NSWorkspace.shared.open([copy], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                BridgeLog.error("Couldn't open the third-party notices: \(error)", category: .app)
            }
        }
    }
}
