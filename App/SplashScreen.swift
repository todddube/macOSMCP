//
//  SplashScreen.swift
//  MacBridge (app) · MacBridge
//
//  The launch splash: the About card for a moment, then a flight into the menu-bar icon.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import MacBridgeKit
import SwiftUI

/// Shows MacBridge's card for a moment at launch, then flies the icon into the
/// menu bar, so it's clear where a menu-bar-only app went.
///
/// Skipped when an AI client started the app in the background (the shim sets
/// ``AppLauncher/launchedByEnvironmentKey``), so starting a conversation never puts
/// a window in front of the user, and when it is switched off in Settings → General.
/// With Reduce Motion on, the card only fades: in without the spring, rotation or
/// rise, and out in place instead of flying.
///
/// The windows are non-activating panels: the splash never takes focus or shows a
/// Dock icon, and a click on the card just ends it early.
@MainActor
enum SplashScreen {

    /// The UserDefaults key behind Settings → General → "Show splash screen at launch".
    static let enabledKey = "showSplashAtLaunch"

    /// How long the card stays up once it has appeared.
    private static let holdSeconds = 2.0
    /// Room around the card for its shadow, which SwiftUI draws inside the window.
    fileprivate static let margin: CGFloat = 32
    fileprivate static let cardWidth: CGFloat = 320
    fileprivate static let iconSize: CGFloat = 88
    /// Above the status-bar level, so the flight and the ripple draw over the menu
    /// bar, and never equal to it, which ``StatusItemController`` reads as the icon.
    private static let overMenuBar = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private static var card: NSPanel?
    private static var model: SplashModel?
    private static var isLeaving = false

    /// Show the splash, unless it is switched off or a client launched the app.
    static func showIfWanted() {
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        let environment = ProcessInfo.processInfo.environment
        let byClient = environment[AppLauncher.launchedByEnvironmentKey] == AppLauncher.launchedByClient
        guard enabled, !byClient, card == nil else { return }
        show()
    }

    private static func show() {
        let model = SplashModel()
        let panel = makePanel(level: .floating)
        let host = NSHostingView(rootView: SplashCard(model: model, dismiss: { collapse() }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        // Centred on the screen the mouse is on, like the About and Settings windows.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()

        self.card = panel
        self.model = model
        // On the next pass, once the hidden state has drawn, so the change animates.
        DispatchQueue.main.async { model.phase = .shown }
        DispatchQueue.main.asyncAfter(deadline: .now() + SplashModel.appearSeconds + holdSeconds) {
            collapse()
        }
    }

    /// End the splash: fly the icon into the menu-bar icon, or fade out when there
    /// is nowhere to fly to (the icon is hidden or crowded out) or motion is reduced.
    private static func collapse() {
        guard let card, let model, !isLeaving else { return }
        isLeaving = true

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion, let target = statusItemFrame(on: card.screen),
              let start = iconFrameOnScreen(in: card) else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                card.animator().alphaValue = 0
            }, completionHandler: {
                // AppKit calls this on the main thread, but the closure isn't marked so.
                MainActor.assumeIsolated { finish() }
            })
            return
        }

        // The icon leaves on its own panel, so the card can fade around it.
        let flyer = makePanel(level: overMenuBar)
        let image = NSImageView(image: NSApp.applicationIconImage)
        image.imageScaling = .scaleProportionallyUpOrDown
        flyer.contentView = image
        flyer.setFrame(start, display: true)
        flyer.orderFrontRegardless()
        model.phase = .leaving

        // A square on the menu-bar icon, a little smaller than the bar is tall.
        let side = target.height * 0.8
        let landing = NSRect(x: target.midX - side / 2, y: target.midY - side / 2, width: side, height: side)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            card.animator().alphaValue = 0
        })
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.55
            // Slow to leave, fast to land: an ease-in with a long tail.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.85, 0.35)
            flyer.animator().setFrame(landing, display: true)
            flyer.animator().alphaValue = 0.85
        }, completionHandler: {
            MainActor.assumeIsolated {
                flyer.close()
                ripple(at: NSPoint(x: target.midX, y: target.midY))
                finish()
            }
        })
    }

    private static func finish() {
        card?.close()
        card = nil
        model = nil
        isLeaving = false
    }

    /// A ring that spreads from the menu-bar icon once the flight lands.
    private static func ripple(at center: NSPoint) {
        let side: CGFloat = 64
        let panel = makePanel(level: overMenuBar)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: SplashRipple())
        panel.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                       display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + SplashRipple.seconds) { panel.close() }
    }

    /// The menu-bar icon's frame on screen, if it is actually showing. On macOS 26
    /// and later it can be hidden in System Settings, and on a crowded menu bar it
    /// can sit behind the notch; either way there is nothing to fly to. Only the
    /// card's own screen counts: with several displays the icon's window may be on
    /// another menu bar, and a flight across monitors reads as a glitch.
    private static func statusItemFrame(on screen: NSScreen?) -> NSRect? {
        guard let screen, let window = NSApp.windows.first(where: {
            StatusItemController.isStatusItemWindow($0) && $0.isVisible
                && $0.occlusionState.contains(.visible)
        }) else { return nil }
        let frame = window.frame
        return screen.frame.intersects(frame) ? frame : nil
    }

    /// Where the card's icon sits on screen, from the frame its view reports.
    private static func iconFrameOnScreen(in panel: NSPanel) -> NSRect? {
        guard let local = model?.iconFrame, !local.isEmpty, let view = panel.contentView else { return nil }
        // SwiftUI reports a top-left origin; the view's own space may not be flipped.
        let rect = view.isFlipped ? local
            : NSRect(x: local.minX, y: view.bounds.height - local.maxY, width: local.width, height: local.height)
        return panel.convertToScreen(view.convert(rect, to: nil))
    }

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow; a window shadow would lag behind the fades.
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        return panel
    }
}

/// What the card shows and where its icon is, shared between the panel and the view.
@MainActor
private final class SplashModel: ObservableObject {
    enum Phase { case hidden, shown, leaving }

    /// How long the card takes to come in, before the hold starts.
    static let appearSeconds = 0.6

    @Published var phase: Phase = .hidden
    /// The icon's frame in the card's coordinate space, top-left origin.
    var iconFrame: CGRect = .zero
}

/// The card: the About window's icon, name and version, and a one-line summary.
private struct SplashCard: View {
    @ObservedObject var model: SplashModel
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Bool { model.phase == .shown }
    /// Whether the card scales and turns as it comes in; with Reduce Motion it only fades.
    private var moves: Bool { model.phase == .hidden && !reduceMotion }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: SplashScreen.iconSize, height: SplashScreen.iconSize)
                .background(alignment: .center) { glow }
                // The flyer takes the icon's place when the card leaves.
                .opacity(model.phase == .leaving ? 0 : 1)
                .scaleEffect(moves ? 0.55 : 1)
                .rotationEffect(.degrees(moves ? -12 : 0))
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: model.phase)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { model.iconFrame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in model.iconFrame = frame }
                    }
                }
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("MacBridge")
                    .font(.title2.weight(.semibold))
                Text(AboutView.versionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .modifier(Rise(shown: shown, delay: 0.12))

            Text("Calendar and Reminders for your AI assistants. MacBridge lives in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Rise(shown: shown, delay: 0.22))
        }
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: SplashScreen.cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .scaleEffect(reduceMotion ? 1 : (model.phase == .hidden ? 0.92 : (model.phase == .leaving ? 0.96 : 1)))
        .opacity(model.phase == .hidden ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: model.phase)
        .padding(SplashScreen.margin)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Closes the splash screen.")
    }

    /// A soft halo behind the icon that swells once as the card comes in.
    private var glow: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.35))
            .blur(radius: 18)
            .scaleEffect(reduceMotion ? 1.25 : (shown ? 1.25 : 0.4))
            .opacity(shown ? 0.9 : 0)
            .animation(.easeOut(duration: 0.8).delay(0.1), value: shown)
    }
}

/// Fades a line of text in while it rises into place, after `delay`.
private struct Rise: ViewModifier {
    let shown: Bool
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(.easeOut(duration: 0.35).delay(shown ? delay : 0), value: shown)
    }
}

/// The ring that spreads from the menu-bar icon when the flight lands.
private struct SplashRipple: View {
    static let seconds = 0.5

    @State private var spread = false

    var body: some View {
        Circle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .scaleEffect(spread ? 1 : 0.3)
            .opacity(spread ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: Self.seconds)) { spread = true }
            }
    }
}
