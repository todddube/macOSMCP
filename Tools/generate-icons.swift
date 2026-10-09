#!/usr/bin/env swift
//
//  generate-icons.swift
//  Tools · MacBridge
//
//  Draws the app icon and menu-bar icons with CoreGraphics and writes them into
//  App/Assets.xcassets.
//
//  Committed as code rather than as opaque binaries so the artwork is reviewable in
//  a diff and tweakable without a design tool. No dependencies: no SVG converter or
//  image tool needs installing.
//
//  Run with: make icons
//
//  Copyright © 2026 Todd Dube. Licensed under the MIT License; see LICENSE.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output locations

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = repoRoot.appendingPathComponent("App/Assets.xcassets")
let appIconSet = catalog.appendingPathComponent("AppIcon.appiconset")

// MARK: - Drawing helpers

/// A square sRGB bitmap context with premultiplied alpha. Traps on failure: this is a
/// developer script, and a half-written icon set is worse than stopping.
func makeContext(size: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(size)px context") }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}

/// Encode the context as PNG at `url`, creating the folder as needed.
func write(_ context: CGContext, to url: URL) {
    guard let image = context.makeImage() else { fatalError("no image from context") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try! data.write(to: url)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Fill `path` with an evenly spaced linear gradient through `colors`.
func fillGradient(_ context: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors as CFArray,
        locations: colors.indices.map { CGFloat($0) / CGFloat(colors.count - 1) }
    )!
    context.drawLinearGradient(gradient, start: from, end: to, options: [])
    context.restoreGState()
}

// MARK: - App icon
//
// A Mac mini as a plinth, with a suspension bridge spanning above it: the machine
// on one side, the assistant on the other, MacBridge as the span between.
//
// Composed to survive 16px. At that size it reduces to a blue tile, a pale slab and
// a bright arc — which is still legible as "bridge over a box". Fine detail (the
// hangers, the port, the LED) is there for 256px and up and simply disappears
// cleanly below that rather than turning to mud.

/// The app icon at `size` pixels square.
func drawAppIcon(size: Int) -> CGContext {
    let context = makeContext(size: size)
    let s = CGFloat(size)
    func u(_ fraction: CGFloat) -> CGFloat { fraction * s }

    // macOS icons sit inset inside their canvas rather than filling it.
    let plate = CGRect(x: u(0.0977), y: u(0.0977), width: u(0.8047), height: u(0.8047))
    let plateRadius = u(0.1836)

    // Night-sky blue: reads as "system utility" and keeps the white bridge bright.
    fillGradient(
        context,
        path: roundedRect(plate, radius: plateRadius),
        colors: [rgb(38, 92, 168), rgb(16, 38, 82)],
        from: CGPoint(x: plate.minX, y: plate.maxY),
        to: CGPoint(x: plate.maxX, y: plate.minY)
    )

    // A soft highlight across the top so the tile is not flat.
    fillGradient(
        context,
        path: roundedRect(plate, radius: plateRadius),
        colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)],
        from: CGPoint(x: plate.midX, y: plate.maxY),
        to: CGPoint(x: plate.midX, y: plate.midY)
    )

    // ── Mac mini ────────────────────────────────────────────────────────────
    // Straight-on with a visible top face: a flat square slab, which is what the
    // machine actually looks like and what reads at small sizes.
    let miniWidth = plate.width * 0.62
    let miniHeight = plate.height * 0.20
    let mini = CGRect(
        x: plate.midX - miniWidth / 2,
        y: plate.minY + plate.height * 0.13,
        width: miniWidth,
        height: miniHeight
    )
    let miniRadius = miniHeight * 0.30

    // Drop shadow grounds it on the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -u(0.012)), blur: u(0.03),
                      color: rgb(0, 0, 0, 0.45))
    context.addPath(roundedRect(mini, radius: miniRadius))
    context.setFillColor(rgb(214, 218, 224))
    context.fillPath()
    context.restoreGState()

    // Body: brushed aluminium, lighter at the top.
    fillGradient(
        context,
        path: roundedRect(mini, radius: miniRadius),
        colors: [rgb(238, 241, 245), rgb(178, 184, 194)],
        from: CGPoint(x: mini.midX, y: mini.maxY),
        to: CGPoint(x: mini.midX, y: mini.minY)
    )

    // The darker top face, which is what makes it read as a slab rather than a bar.
    let topFace = CGRect(x: mini.minX, y: mini.maxY - miniHeight * 0.30,
                         width: mini.width, height: miniHeight * 0.30)
    context.saveGState()
    context.addPath(roundedRect(mini, radius: miniRadius))
    context.clip()
    fillGradient(
        context,
        path: CGPath(rect: topFace, transform: nil),
        colors: [rgb(120, 128, 140), rgb(164, 172, 184)],
        from: CGPoint(x: topFace.midX, y: topFace.maxY),
        to: CGPoint(x: topFace.midX, y: topFace.minY)
    )
    context.restoreGState()

    // Detail that only matters at large sizes: the power LED and a rear port.
    if size >= 128 {
        let led = CGRect(x: mini.maxX - mini.width * 0.10,
                         y: mini.minY + miniHeight * 0.30,
                         width: miniHeight * 0.13, height: miniHeight * 0.13)
        context.setFillColor(rgb(150, 235, 160))
        context.fillEllipse(in: led)

        let port = CGRect(x: mini.minX + mini.width * 0.08,
                          y: mini.minY + miniHeight * 0.30,
                          width: mini.width * 0.14, height: miniHeight * 0.12)
        context.setFillColor(rgb(90, 98, 110, 0.7))
        context.addPath(roundedRect(port, radius: port.height / 2))
        context.fillPath()
    }

    // ── Suspension bridge ───────────────────────────────────────────────────
    let deckY = plate.minY + plate.height * 0.52
    let spanInset = plate.width * 0.10
    let leftX = plate.minX + spanInset
    let rightX = plate.maxX - spanInset
    let towerTop = plate.minY + plate.height * 0.84
    let towerLeftX = plate.minX + plate.width * 0.30
    let towerRightX = plate.maxX - plate.width * 0.30

    let lineWidth = max(s * 0.016, 1)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Cables first, so the towers and deck sit over them.
    context.setStrokeColor(rgb(255, 214, 120))
    context.setLineWidth(lineWidth * 0.85)
    for (startX, endX) in [(leftX, towerLeftX), (towerLeftX, towerRightX), (towerRightX, rightX)] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: startX == leftX ? deckY : towerTop))
        // A catenary, approximated by a quadratic through the low point.
        let sag = (endX - startX) * 0.28
        path.addQuadCurve(
            to: CGPoint(x: endX, y: endX == rightX ? deckY : towerTop),
            control: CGPoint(x: (startX + endX) / 2, y: min(deckY, towerTop) + sag * 0.25)
        )
        context.addPath(path)
        context.strokePath()
    }

    // Hangers: fine verticals from cable to deck. Large sizes only.
    if size >= 256 {
        context.setStrokeColor(rgb(255, 214, 120, 0.8))
        context.setLineWidth(lineWidth * 0.35)
        let steps = 9
        for i in 1..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = towerLeftX + (towerRightX - towerLeftX) * t
            // Height of the quadratic cable at t between the two towers.
            let sag = (towerRightX - towerLeftX) * 0.28
            let control = towerTop + sag * 0.25 - (towerTop - deckY) * 0.55
            let y = pow(1 - t, 2) * towerTop + 2 * (1 - t) * t * control + pow(t, 2) * towerTop
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x, y: deckY))
            context.strokePath()
        }
    }

    // Towers.
    context.setStrokeColor(rgb(255, 255, 255))
    context.setLineWidth(lineWidth)
    for x in [towerLeftX, towerRightX] {
        context.move(to: CGPoint(x: x, y: deckY - plate.height * 0.06))
        context.addLine(to: CGPoint(x: x, y: towerTop))
        context.strokePath()
    }

    // Deck: the strongest horizontal, and the line that carries the shape at 16px.
    context.setLineWidth(lineWidth * 1.5)
    context.move(to: CGPoint(x: leftX, y: deckY))
    context.addLine(to: CGPoint(x: rightX, y: deckY))
    context.strokePath()

    return context
}

// MARK: - Menu bar icon
//
// An "AI bridge": the same span, reduced to a glyph, with three nodes along the
// cable standing in for the assistant side of the link.
//
// Template artwork, so it must be black-with-alpha only — macOS tints it for light,
// dark and highlighted menu bars, and any colour here would be thrown away.

/// The menu-bar template glyph at `size` pixels square; `alert` draws the variant
/// shown when something needs attention.
func drawMenuBarIcon(size: Int, alert: Bool) -> CGContext {
    let context = makeContext(size: size)
    let s = CGFloat(size)

    // Menu-bar glyphs need breathing room or they look oversized next to Apple's.
    let inset = s * 0.08
    let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // Light enough that the towers and cable stay separate shapes. A heavier stroke
    // merged them into an illegible blob at 18pt.
    let stroke = max(s * 0.062, 1)
    context.setStrokeColor(.black)
    context.setFillColor(.black)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let deckY = box.minY + box.height * 0.34
    let towerTop = box.maxY
    let towerLeftX = box.minX + box.width * 0.27
    let towerRightX = box.maxX - box.width * 0.27

    // A shallow sag, not a deep one. Dropping the cable far between the towers left a
    // V between two verticals, and the silhouette read as the letter M.
    let sagBottom = deckY + (towerTop - deckY) * 0.66
    let controlY = 2 * sagBottom - towerTop

    context.setLineWidth(stroke * 0.9)

    // Side cables sweeping from the deck ends up to the tower tops. These carry the
    // recognisable suspension-bridge silhouette; without them it is just two posts.
    for (endX, towerX) in [(box.minX, towerLeftX), (box.maxX, towerRightX)] {
        let side = CGMutablePath()
        side.move(to: CGPoint(x: endX, y: deckY))
        side.addQuadCurve(
            to: CGPoint(x: towerX, y: towerTop),
            control: CGPoint(x: (endX + towerX) / 2, y: deckY + (towerTop - deckY) * 0.25)
        )
        context.addPath(side)
        context.strokePath()
    }

    // Main span.
    let cable = CGMutablePath()
    cable.move(to: CGPoint(x: towerLeftX, y: towerTop))
    cable.addQuadCurve(to: CGPoint(x: towerRightX, y: towerTop),
                       control: CGPoint(x: box.midX, y: controlY))
    context.addPath(cable)
    context.strokePath()

    // Towers: the two verticals that make it a suspension bridge rather than an arch.
    context.setLineWidth(stroke)
    for x in [towerLeftX, towerRightX] {
        context.move(to: CGPoint(x: x, y: deckY))
        context.addLine(to: CGPoint(x: x, y: towerTop))
        context.strokePath()
    }

    // Deck, full width: the anchor line, and the one element that must survive at 1x.
    context.setLineWidth(stroke * 1.2)
    context.move(to: CGPoint(x: box.minX, y: deckY))
    context.addLine(to: CGPoint(x: box.maxX, y: deckY))
    context.strokePath()

    // A single node at the centre of the span — the "AI" half of the metaphor, a link
    // rather than just a crossing. Omitted at 1x, where it only thickens the cable.
    if size >= 36 {
        let nodeRadius = stroke * 0.78
        context.fillEllipse(in: CGRect(x: box.midX - nodeRadius, y: sagBottom - nodeRadius,
                                       width: nodeRadius * 2, height: nodeRadius * 2))
    }

    // The alert variant breaks the span, so "something is wrong" shows in the menu bar
    // itself rather than only once the panel is open.
    if alert {
        context.setBlendMode(.clear)
        context.fill(CGRect(x: box.midX - stroke * 1.3, y: deckY - stroke * 1.4,
                            width: stroke * 2.6, height: stroke * 2.8))
        context.setBlendMode(.normal)
    }

    return context
}

// MARK: - Asset catalog

/// One entry per required macOS app-icon size, as `idiom: mac` expects.
let appIconSizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

/// Write every app-icon PNG and the set's `Contents.json`.
func generateAppIcon() {
    var images: [String] = []
    for (points, scale) in appIconSizes {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(drawAppIcon(size: pixels), to: appIconSet.appendingPathComponent(name))
        images.append("""
                {
                  "filename" : "\(name)",
                  "idiom" : "mac",
                  "scale" : "\(scale)x",
                  "size" : "\(points)x\(points)"
                }
            """)
    }

    let contents = """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "generate-icons.swift",
            "version" : 1
          }
        }
        """
    try! contents.write(to: appIconSet.appendingPathComponent("Contents.json"),
                        atomically: true, encoding: .utf8)
    print("  AppIcon.appiconset — \(appIconSizes.count) images")
}

/// Write a 1x/2x/3x template image set named `name`.
func generateMenuBarIcon(named name: String, alert: Bool) {
    let set = catalog.appendingPathComponent("\(name).imageset")
    var images: [String] = []

    // 18pt is the menu-bar convention; 1x/2x/3x covers every display.
    for scale in 1...3 {
        let pixels = 18 * scale
        let filename = "\(name)\(scale > 1 ? "@\(scale)x" : "").png"
        write(drawMenuBarIcon(size: pixels, alert: alert), to: set.appendingPathComponent(filename))
        images.append("""
                {
                  "filename" : "\(filename)",
                  "idiom" : "universal",
                  "scale" : "\(scale)x"
                }
            """)
    }

    let contents = """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "generate-icons.swift",
            "version" : 1
          },
          "properties" : {
            "template-rendering-intent" : "template"
          }
        }
        """
    try! contents.write(to: set.appendingPathComponent("Contents.json"),
                        atomically: true, encoding: .utf8)
    print("  \(name).imageset — 3 images, template")
}

// MARK: - Main

try? FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
try! """
    {
      "info" : {
        "author" : "generate-icons.swift",
        "version" : 1
      }
    }
    """.write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Generating icons into App/Assets.xcassets")
generateAppIcon()
generateMenuBarIcon(named: "MenuBarBridge", alert: false)
generateMenuBarIcon(named: "MenuBarBridgeAlert", alert: true)
print("Done.")
