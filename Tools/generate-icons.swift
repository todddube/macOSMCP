#!/usr/bin/env swift
//
//  generate-icons.swift
//  Tools · MacBridge
//
//  Draws the app icon's artwork layers with CoreGraphics and writes them, with an
//  icon.json, into the Icon Composer bundle App/AppIcon.icon.
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
let iconBundle = repoRoot.appendingPathComponent("App/AppIcon.icon")
let iconAssets = iconBundle.appendingPathComponent("Assets")

// MARK: - Drawing helpers

/// A square sRGB bitmap context with premultiplied alpha. Traps on failure: this is a
/// developer script, and a half-written icon is worse than stopping.
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
// The icon is LAYERED, in the Icon Composer format: the HIG asks for square,
// unmasked layers and leaves masking, highlights, shadow and the dark, tinted and
// clear looks to the system. So nothing here is masked, shadowed or highlighted:
//   - background: a gradient fill declared in icon.json, not an image;
//   - "Mac mini" group: one 1024px transparent layer;
//   - "Bridge" group: two layers, cables (with hangers) and structure (towers, deck).
// Each layer is a full-canvas transparent PNG, so every layer shares one coordinate
// space and icon.json needs no per-layer offsets.

/// Canvas edge for every layer, in pixels.
let layerSize = 1024

/// Shared geometry. The system supplies the margin and the squircle, so the artwork
/// is kept inside a centred 80% box.
struct Geometry {
    let s = CGFloat(layerSize)
    var plate: CGRect { CGRect(x: s * 0.10, y: s * 0.10, width: s * 0.80, height: s * 0.80) }
    var lineWidth: CGFloat { s * 0.020 }
    var deckY: CGFloat { plate.minY + plate.height * 0.52 }
    var leftX: CGFloat { plate.minX + plate.width * 0.10 }
    var rightX: CGFloat { plate.maxX - plate.width * 0.10 }
    var towerTop: CGFloat { plate.minY + plate.height * 0.84 }
    var towerLeftX: CGFloat { plate.minX + plate.width * 0.30 }
    var towerRightX: CGFloat { plate.maxX - plate.width * 0.30 }
}

/// The Mac mini slab: aluminium body, darker top face, LED and port. No shadow;
/// the system casts one for the group.
func drawMini(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    let plate = g.plate
    let miniWidth = plate.width * 0.62
    let miniHeight = plate.height * 0.20
    let mini = CGRect(
        x: plate.midX - miniWidth / 2,
        y: plate.minY + plate.height * 0.13,
        width: miniWidth,
        height: miniHeight
    )
    let miniRadius = miniHeight * 0.30

    fillGradient(
        context,
        path: roundedRect(mini, radius: miniRadius),
        colors: [rgb(238, 241, 245), rgb(178, 184, 194)],
        from: CGPoint(x: mini.midX, y: mini.maxY),
        to: CGPoint(x: mini.midX, y: mini.minY)
    )

    // The darker top face, which makes it read as a slab rather than a bar.
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
    return context
}

/// Main cables and hangers, in warm gold. The hangers are drawn heavier than a flat
/// icon would need: the system's glass and tinted looks erase hairlines.
func drawCables(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(rgb(255, 214, 120))

    context.setLineWidth(g.lineWidth * 0.85)
    for (startX, endX) in [(g.leftX, g.towerLeftX), (g.towerLeftX, g.towerRightX), (g.towerRightX, g.rightX)] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: startX == g.leftX ? g.deckY : g.towerTop))
        // A catenary, approximated by a quadratic through the low point.
        let sag = (endX - startX) * 0.28
        path.addQuadCurve(
            to: CGPoint(x: endX, y: endX == g.rightX ? g.deckY : g.towerTop),
            control: CGPoint(x: (startX + endX) / 2, y: min(g.deckY, g.towerTop) + sag * 0.25)
        )
        context.addPath(path)
        context.strokePath()
    }

    context.setLineWidth(g.lineWidth * 0.5)
    let steps = 9
    for i in 1..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = g.towerLeftX + (g.towerRightX - g.towerLeftX) * t
        let sag = (g.towerRightX - g.towerLeftX) * 0.28
        let control = g.towerTop + sag * 0.25 - (g.towerTop - g.deckY) * 0.55
        let y = pow(1 - t, 2) * g.towerTop + 2 * (1 - t) * t * control + pow(t, 2) * g.towerTop
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x, y: g.deckY))
        context.strokePath()
    }
    return context
}

/// Towers and deck, in white: the line that carries the shape at 16px.
func drawStructure(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    context.setLineCap(.round)
    context.setStrokeColor(rgb(255, 255, 255))
    context.setLineWidth(g.lineWidth)
    for x in [g.towerLeftX, g.towerRightX] {
        context.move(to: CGPoint(x: x, y: g.deckY - g.plate.height * 0.06))
        context.addLine(to: CGPoint(x: x, y: g.towerTop))
        context.strokePath()
    }
    context.setLineWidth(g.lineWidth * 1.5)
    context.move(to: CGPoint(x: g.leftX, y: g.deckY))
    context.addLine(to: CGPoint(x: g.rightX, y: g.deckY))
    context.strokePath()
    return context
}

// MARK: - Icon Composer bundle
//
// Format learned from Xcode's own "Icon Composer Icon" file template
// (Xcode.app/.../Templates/File Templates/macOS/Resource) and the key names in
// Icon Composer's frameworks, then checked by rendering with `ictool`.

/// icon.json: a night-sky gradient fill, with glass and specular on the artwork so the
/// system lights it. There is deliberately no dark fill specialization: ictool ignored
/// one, and the system's own dark treatment (near-black tile, artwork kept) reads well. Groups are listed top-down, so the
/// bridge sits over the Mac mini.
let iconJSON = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.14902,0.36078,0.65882,1.00000",
          "srgb:0.06275,0.14902,0.32157,1.00000"
        ],
        "orientation" : {
          "start" : { "x" : 0.1, "y" : 0 },
          "stop" : { "x" : 0.9, "y" : 1 }
        }
      },
      "groups" : [
        {
          "name" : "Bridge",
          "layers" : [
            { "name" : "Structure", "image-name" : "bridge-structure.png", "glass" : true },
            { "name" : "Cables", "image-name" : "bridge-cables.png", "glass" : false }
          ],
          "lighting" : "individual",
          "shadow" : { "kind" : "layer-color", "opacity" : 0.4 },
          "specular" : true,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        },
        {
          "name" : "Mac mini",
          "layers" : [
            { "name" : "Mac mini", "image-name" : "mac-mini.png", "glass" : true }
          ],
          "lighting" : "combined",
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "specular" : true,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : {
        "squares" : [ "macOS" ]
      }
    }
    """

/// Write the layers and icon.json, replacing any previous bundle.
func generateAppIcon() {
    let g = Geometry()
    try? FileManager.default.removeItem(at: iconBundle)
    write(drawMini(g), to: iconAssets.appendingPathComponent("mac-mini.png"))
    write(drawCables(g), to: iconAssets.appendingPathComponent("bridge-cables.png"))
    write(drawStructure(g), to: iconAssets.appendingPathComponent("bridge-structure.png"))
    try! iconJSON.write(to: iconBundle.appendingPathComponent("icon.json"),
                        atomically: true, encoding: .utf8)
    print("  AppIcon.icon — 3 layers, \(layerSize)px")
}

// MARK: - Main

print("Generating App/AppIcon.icon")
generateAppIcon()
print("Done.")
