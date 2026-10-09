//
//  BridgeTraffic.swift
//  MacBridge (app) · MacBridge
//
//  Animated traffic across the bridge glyph, for the menu bar and the panel.
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import SwiftUI

/// Tool calls drawn as cars crossing the bridge.
///
/// The activity list says what happened; this says that something is happening,
/// at a glance, without opening anything. Reads drive from the Mac (left) to the
/// assistant (right) on top of the deck, writes the other way beneath it, a destructive call is a heavier car,
/// and a failed one drops through the deck halfway across. A client connecting or
/// leaving rings the node on the cable.
///
/// Any activity also sets the bridge busy for a while: cars keep zipping both ways
/// for `linger` seconds after the last call or connection, so a working session
/// looks alive between calls rather than flashing one car at a time. Those ambient
/// cars sit under the real ones, which still show kind and failure.
///
/// The clock only runs while the bridge is busy, so an idle app costs nothing: the
/// menu bar then shows one still frame of the bridge with no cars.
@MainActor
final class BridgeTraffic: ObservableObject {

    /// The kind of call a packet represents, which picks its colour in the panel.
    enum Flow: Sendable {
        case read
        case write
        case destructive
    }

    /// One car crossing the bridge, departing at `start`.
    struct Packet: Sendable {
        let start: Date
        let flow: Flow
        let ok: Bool
        /// Background traffic while busy, not a specific call.
        var ambient = false
    }

    /// Everything one frame needs, copied out so an `NSImage` drawing handler —
    /// which AppKit may call later, off the current state — draws a consistent frame.
    struct Snapshot: Sendable {
        var now: Date
        var packets: [Packet]
        var pulseStart: Date?
        var reduceMotion: Bool
    }

    /// Bumped every frame while animating; observing it is what redraws the icon.
    @Published private(set) var now = Date()
    @Published private(set) var isActive = false

    private var packets: [Packet] = []
    private var pulseStart: Date?
    private var timer: Timer?
    /// Call times over the last minute, for the panel's rate line.
    private var recentCalls: [Date] = []
    /// The last call or connection; the bridge stays busy for `linger` after it.
    private var lastActivity: Date?
    private var lastAmbient: Date = .distantPast
    private var ambientRightward = false

    nonisolated static let travelTime: TimeInterval = 0.8
    nonisolated static let pulseTime: TimeInterval = 0.9
    /// Minimum gap between cars, so a burst reads as a convoy rather than one blob.
    private static let spacing: TimeInterval = 0.12
    /// How long the bridge keeps busy traffic after the last activity.
    private static let linger: TimeInterval = 10
    /// How often an ambient car sets off while busy, and the most on the deck at
    /// once — enough to read as traffic without crowding out the real calls.
    private static let ambientInterval: TimeInterval = 0.3
    private static let maxAmbient = 4
    /// Beyond this many queued cars the rest are dropped — the log still counts them,
    /// and a two-minute queue of animation would misrepresent what is happening now.
    private static let maxQueued = 8

    var snapshot: Snapshot {
        Snapshot(
            now: now, packets: packets, pulseStart: pulseStart,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Tool calls sent in the 60 seconds before `date`, for the panel's rate line.
    func callsInLastMinute(at date: Date = Date()) -> Int {
        recentCalls.filter { date.timeIntervalSince($0) < 60 }.count
    }

    // MARK: Events

    /// Queue a packet for a completed call, spaced behind the previous one so a
    /// burst reads as a stream. Dropped when the queue is already full.
    func send(_ flow: Flow, ok: Bool) {
        let date = Date()
        recentCalls.append(date)
        recentCalls.removeAll { date.timeIntervalSince($0) >= 60 }
        lastActivity = date

        guard packets.filter({ $0.start > date }).count < Self.maxQueued else { return }
        let start = max(date, (packets.last?.start ?? .distantPast) + Self.spacing)
        packets.append(Packet(start: start, flow: flow, ok: ok))
        run()
    }

    /// Ring the node once, for a client connecting or leaving.
    func pulse() {
        pulseStart = Date()
        lastActivity = pulseStart
        run()
    }

    // MARK: Clock

    private func run() {
        now = Date()
        isActive = true
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the icon keeps moving while the menu is open and tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let date = Date()
        packets.removeAll { date.timeIntervalSince($0.start) > Self.travelTime }
        if let start = pulseStart, date.timeIntervalSince(start) > Self.pulseTime {
            pulseStart = nil
        }
        spawnAmbient(at: date)
        now = date

        if packets.isEmpty && pulseStart == nil {
            timer?.invalidate()
            timer = nil
            isActive = false
        }
    }

    var isBusy: Bool {
        guard let lastActivity else { return false }
        return Date().timeIntervalSince(lastActivity) < Self.linger
    }

    /// Alternate directions so the bridge reads as two-way traffic. Skipped under
    /// Reduce Motion, where a constant stream would be exactly what is unwanted.
    private func spawnAmbient(at date: Date) {
        guard isBusy,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              date.timeIntervalSince(lastAmbient) >= Self.ambientInterval,
              packets.filter(\.ambient).count < Self.maxAmbient
        else { return }
        lastAmbient = date
        ambientRightward.toggle()
        packets.append(Packet(start: date, flow: ambientRightward ? .read : .write, ok: true, ambient: true))
    }

    // MARK: Rendering

    /// The menu-bar frame: the bridge in the menu bar's own text colour (white on a
    /// dark bar), with the panel's coloured cars.
    ///
    /// Not a template image, because a template can't carry colour. The palette is
    /// resolved inside the drawing handler, which AppKit runs, and caches, once per
    /// appearance it's drawn in, so the bridge follows the menu bar's own appearance
    /// rather than the system's: seen drawing a light road on a dark, wallpaper-tinted
    /// bar while the system was in Light Mode.
    func menuBarImage(alert: Bool) -> NSImage {
        let snapshot = snapshot
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            BridgeRenderer.draw(cg, in: rect, snapshot: snapshot, palette: .menuBar, alert: alert)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The bridge glyph's geometry, y-up.
///
/// The app icon's suspension span (Tools/generate-icons.swift), simplified for 18pt,
/// so the menu bar and the Dock read as one design. Heights and stroke come from the
/// rect's height, so a wider rect lengthens the span instead of stretching it — the
/// panel's strip gets a long road with round cars.
struct BridgeGlyph {
    let box: CGRect
    let stroke: CGFloat
    let deckY: CGFloat
    let towerTop: CGFloat
    let towerLeftX: CGFloat
    let towerRightX: CGFloat
    let sagBottom: CGFloat
    let controlY: CGFloat

    init(in rect: CGRect) {
        let s = min(rect.width, rect.height)
        let inset = s * 0.08
        box = rect.insetBy(dx: inset, dy: inset)
        stroke = s * 0.062
        deckY = box.minY + box.height * 0.34
        towerTop = box.maxY
        towerLeftX = box.minX + box.width * 0.27
        towerRightX = box.maxX - box.width * 0.27
        sagBottom = deckY + (towerTop - deckY) * 0.66
        controlY = 2 * sagBottom - towerTop
    }

    var packetRadius: CGFloat { stroke * 1.15 }
    var node: CGPoint { CGPoint(x: box.midX, y: sagBottom) }

    /// Where a car sits at `progress` (0…1) along the deck.
    ///
    /// Two lanes: rightward cars ride on top of the deck, leftward ones underneath.
    /// One lane at 18pt turned busy two-way traffic into a single smear of dots.
    func carCenter(progress: CGFloat, rightward: Bool) -> CGPoint {
        let r = packetRadius
        let from = box.minX - r, to = box.maxX + r
        let t = rightward ? progress : 1 - progress
        let offset = stroke * 0.6 + r
        return CGPoint(x: from + (to - from) * t, y: rightward ? deckY + offset : deckY - offset)
    }

    /// True while a point is still on the road, so a tail never trails out past the
    /// end the car entered from.
    func isOnDeck(_ point: CGPoint) -> Bool {
        point.x >= box.minX - packetRadius && point.x <= box.maxX + packetRadius
    }
}

/// Draws the bridge and its traffic into a CoreGraphics context.
///
/// One renderer for both places, each with its own palette: the menu bar's is tuned
/// for an 18pt icon on a translucent bar, the panel's for its wider strip.
enum BridgeRenderer {

    /// The colours and options for one destination.
    struct Palette {
        /// The bridge itself: towers, cables and the deck the cars drive along.
        var structure: CGColor
        var read: CGColor
        var write: CGColor
        var destructive: CGColor
        var failed: CGColor
        /// The node and the ring it sends out when a client connects or leaves.
        var accent: CGColor
        /// The panel always shows the node; the menu bar only while it rings, since at
        /// 18pt a permanent node only thickens the cable.
        var showsNode: Bool
        /// How strongly ambient cars draw, so real calls stand out from the traffic.
        var ambientAlpha: CGFloat

        /// The menu bar: the whole bridge in the menu bar's text colour, so it reads
        /// white on a dark bar and black on a light one, with only the cars in colour.
        /// Must be read while the status button's appearance is current, as
        /// `menuBarImage(alert:)` does, or it resolves for the wrong bar.
        static var menuBar: Palette {
            Palette(
                structure: NSColor.labelColor.cgColor,
                read: NSColor.systemBlue.cgColor,
                write: NSColor.systemOrange.cgColor,
                destructive: NSColor.systemRed.cgColor,
                failed: NSColor.systemRed.cgColor,
                accent: NSColor.systemGreen.cgColor,
                showsNode: false,
                ambientAlpha: 0.6
            )
        }

        static var panel: Palette {
            Palette(
                structure: NSColor.secondaryLabelColor.cgColor,
                read: NSColor.systemBlue.cgColor,
                write: NSColor.systemOrange.cgColor,
                destructive: NSColor.systemRed.cgColor,
                failed: NSColor.systemRed.cgColor,
                accent: NSColor.systemGreen.cgColor,
                showsNode: true,
                ambientAlpha: 0.45
            )
        }

        func color(for flow: BridgeTraffic.Flow) -> CGColor {
            switch flow {
            case .read: return read
            case .write: return write
            case .destructive: return destructive
            }
        }
    }

    /// Draw the glyph, its traffic and any pulse for one frame into `cg`.
    static func draw(
        _ cg: CGContext, in rect: CGRect, snapshot: BridgeTraffic.Snapshot,
        palette: Palette, alert: Bool
    ) {
        let glyph = BridgeGlyph(in: rect)
        cg.saveGState()
        defer { cg.restoreGState() }

        drawStructure(cg, glyph: glyph, palette: palette, alert: alert)
        drawPulse(cg, glyph: glyph, snapshot: snapshot, palette: palette)
        for packet in snapshot.packets {
            drawCar(cg, glyph: glyph, packet: packet, snapshot: snapshot, palette: palette)
        }
    }

    // MARK: Structure

    private static func drawStructure(_ cg: CGContext, glyph g: BridgeGlyph, palette: Palette, alert: Bool) {
        cg.setStrokeColor(palette.structure)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        cg.setLineWidth(g.stroke * 0.9)
        for (endX, towerX) in [(g.box.minX, g.towerLeftX), (g.box.maxX, g.towerRightX)] {
            cg.move(to: CGPoint(x: endX, y: g.deckY))
            cg.addQuadCurve(
                to: CGPoint(x: towerX, y: g.towerTop),
                control: CGPoint(x: (endX + towerX) / 2, y: g.deckY + (g.towerTop - g.deckY) * 0.25)
            )
            cg.strokePath()
        }
        cg.move(to: CGPoint(x: g.towerLeftX, y: g.towerTop))
        cg.addQuadCurve(to: CGPoint(x: g.towerRightX, y: g.towerTop),
                        control: CGPoint(x: g.box.midX, y: g.controlY))
        cg.strokePath()

        cg.setLineWidth(g.stroke)
        for x in [g.towerLeftX, g.towerRightX] {
            cg.move(to: CGPoint(x: x, y: g.deckY))
            cg.addLine(to: CGPoint(x: x, y: g.towerTop))
            cg.strokePath()
        }

        cg.setLineWidth(g.stroke * 1.2)
        cg.move(to: CGPoint(x: g.box.minX, y: g.deckY))
        cg.addLine(to: CGPoint(x: g.box.maxX, y: g.deckY))
        cg.strokePath()

        if palette.showsNode {
            fillCircle(cg, at: g.node, radius: g.stroke * 0.78, color: palette.accent)
        }

        if alert {
            cg.setBlendMode(.clear)
            cg.fill(CGRect(x: g.box.midX - g.stroke * 1.3, y: g.deckY - g.stroke * 1.4,
                           width: g.stroke * 2.6, height: g.stroke * 2.8))
            cg.setBlendMode(.normal)
        }
    }

    // MARK: Traffic

    private static func drawPulse(
        _ cg: CGContext, glyph g: BridgeGlyph, snapshot: BridgeTraffic.Snapshot, palette: Palette
    ) {
        guard let start = snapshot.pulseStart else { return }
        let t = CGFloat(min(max(snapshot.now.timeIntervalSince(start) / BridgeTraffic.pulseTime, 0), 1))
        let eased = 1 - (1 - t) * (1 - t)

        fillCircle(cg, at: g.node, radius: g.stroke * 0.78, color: palette.accent)
        let radius = g.stroke * (1 + 3.2 * eased)
        cg.setStrokeColor(palette.accent.copy(alpha: 1 - t) ?? palette.accent)
        cg.setLineWidth(g.stroke * 0.7)
        cg.strokeEllipse(in: CGRect(x: g.node.x - radius, y: g.node.y - radius,
                                    width: radius * 2, height: radius * 2))
    }

    private static func drawCar(
        _ cg: CGContext, glyph g: BridgeGlyph, packet: BridgeTraffic.Packet,
        snapshot: BridgeTraffic.Snapshot, palette: Palette
    ) {
        let elapsed = snapshot.now.timeIntervalSince(packet.start)
        guard elapsed >= 0 else { return }  // still queued
        let t = CGFloat(min(elapsed / BridgeTraffic.travelTime, 1))

        let rightward = packet.flow == .read
        var color = packet.ok ? palette.color(for: packet.flow) : palette.failed
        if packet.ambient { color = color.copy(alpha: palette.ambientAlpha) ?? color }
        var r = g.packetRadius * (packet.flow == .destructive ? 1.3 : 1)

        // Reduced motion: no driving, just a car that appears mid-span and fades.
        if snapshot.reduceMotion {
            let center = g.carCenter(progress: 0.5, rightward: rightward)
            car(cg, glyph: g, at: center, radius: r, color: color.copy(alpha: color.alpha * (1 - t)) ?? color)
            return
        }

        // Smoothstep, so cars pull away and arrive rather than slide at constant speed.
        func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }

        if packet.ok {
            let head = g.carCenter(progress: ease(t), rightward: rightward)
            // A fading tail behind the car is what makes the motion read at 18pt. Its
            // gaps are in points and scale with speed — smoothstep's slope, 0 at the
            // ends and 1.5 mid-span — so it stretches out at speed and closes up as
            // the car pulls away or arrives, the same at any width.
            let speed = 6 * t * (1 - t)
            let gap = r * 1.2 * speed * (rightward ? -1 : 1)
            for (step, alpha) in [(3, 0.12), (2, 0.25), (1, 0.45)] as [(CGFloat, CGFloat)] {
                let ghost = CGPoint(x: head.x + gap * step, y: head.y)
                guard speed > 0.15, g.isOnDeck(ghost) else { continue }
                fillCircle(cg, at: ghost, radius: r * (1 - step * 0.18),
                           color: color.copy(alpha: color.alpha * alpha) ?? color)
            }
            car(cg, glyph: g, at: head, radius: r, color: color)
            return
        }

        // A failed call gets halfway, then drops through the deck and fades.
        if t < 0.5 {
            car(cg, glyph: g, at: g.carCenter(progress: ease(t), rightward: rightward), radius: r, color: color)
        } else {
            let fall = (t - 0.5) * 2
            var center = g.carCenter(progress: 0.5, rightward: rightward)
            center.y -= fall * fall * (g.deckY - g.box.minY + r * 3)
            r *= 1 - fall * 0.3
            car(cg, glyph: g, at: center, radius: r, color: color.copy(alpha: color.alpha * (1 - fall)) ?? color)
        }
    }

    /// A dot with a knocked-out ring, so it stays a separate shape where it passes a
    /// tower or the deck rather than merging into the line.
    private static func car(
        _ cg: CGContext, glyph g: BridgeGlyph, at center: CGPoint, radius: CGFloat, color: CGColor
    ) {
        cg.setBlendMode(.clear)
        fillCircle(cg, at: center, radius: radius + g.stroke * 0.55, color: .black)
        cg.setBlendMode(.normal)
        fillCircle(cg, at: center, radius: radius, color: color)
    }

    private static func fillCircle(_ cg: CGContext, at center: CGPoint, radius: CGFloat, color: CGColor) {
        cg.setFillColor(color)
        cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2))
    }
}

/// The panel's live strip: the same bridge, in colour, with the call rate.
struct BridgeTrafficView: View {
    @ObservedObject var traffic: BridgeTraffic
    let alert: Bool
    let client: String?

    var body: some View {
        HStack(spacing: 10) {
            endLabel("Mac", symbol: "desktopcomputer")
            Canvas { context, size in
                context.withCGContext { cg in
                    // Canvas is y-down; the renderer, like the generator, is y-up.
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    BridgeRenderer.draw(
                        cg, in: CGRect(origin: .zero, size: size),
                        snapshot: traffic.snapshot, palette: .panel, alert: alert
                    )
                }
            }
            .frame(height: 34)
            endLabel(client ?? "Assistant", symbol: "sparkles")
        }
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let count = traffic.callsInLastMinute(at: context.date)
                Text(count == 0 ? "quiet" : "\(count) call\(count == 1 ? "" : "s") in the last minute")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .offset(y: 10)
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bridge traffic")
        .accessibilityValue("\(traffic.callsInLastMinute()) calls in the last minute")
    }

    private func endLabel(_ text: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 58)
    }
}
