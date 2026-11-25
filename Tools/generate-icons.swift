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
// A suspension bridge at dusk, spanning above a Mac mini: the machine on one side,
// the assistant on the other, MacBridge as the span between. A low sun sits in the
// dip of the main cable, which is what gives the icon its warmth and its focal point.
//
// The icon is LAYERED, in the Icon Composer format: the HIG asks for square,
// unmasked layers and leaves masking, highlights, shadow and the dark, tinted and
// clear looks to the system. So nothing here is masked, shadowed or highlighted:
//   - background: a two-colour dusk gradient (Icon Composer allows exactly two) declared in icon.json, not an image;
//   - "Sun" group: one layer, the disc, behind everything;
//   - "Bridge" group: two layers, cables (with hangers) and structure (towers, deck);
//   - "Mac mini" group: one layer.
// Each layer is a full-canvas transparent PNG, so every layer shares one coordinate
// space and icon.json needs no per-layer offsets.
//
// Shapes are solid and strokes heavy on purpose: Liquid Glass lights edges, and the
// tinted and clear looks reduce the artwork to its silhouette, where hairlines vanish.

/// Canvas edge for every layer, in pixels.
let layerSize = 1024

/// Shared geometry. The system supplies the margin and the squircle; the artwork
/// fills a centred 84% box, a little more than the usual 80%, so it reads at 32px.
struct Geometry {
    let s = CGFloat(layerSize)
    var plate: CGRect { CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84) }
    var deckY: CGFloat { plate.minY + plate.height * 0.47 }
    var deckThickness: CGFloat { s * 0.040 }
    var leftX: CGFloat { plate.minX + plate.width * 0.04 }
    var rightX: CGFloat { plate.maxX - plate.width * 0.04 }
    var towerTop: CGFloat { plate.minY + plate.height * 0.88 }
    var towerBase: CGFloat { deckY - plate.height * 0.11 }
    var towerWidth: CGFloat { s * 0.050 }
    var towerLeftX: CGFloat { plate.minX + plate.width * 0.28 }
    var towerRightX: CGFloat { plate.maxX - plate.width * 0.28 }
    var cableWidth: CGFloat { s * 0.026 }
    /// Lowest point of the main span's cable, just above the deck.
    var cableLowY: CGFloat { deckY + plate.height * 0.10 }

    /// The main span's cable height at `x`: a parabola through both tower tops and
    /// the low point, close enough to a catenary at this sag.
    func mainCableY(at x: CGFloat) -> CGFloat {
        let mid = (towerLeftX + towerRightX) / 2
        let half = (towerRightX - towerLeftX) / 2
        let u = (x - mid) / half
        return cableLowY + (towerTop - cableLowY) * u * u
    }
}

/// The low sun: a warm disc centred in the dip of the main cable and cut by the
/// deck, so the bridge reads in silhouette against it.
func drawSun(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    let radius = g.s * 0.205
    let centre = CGPoint(x: g.s / 2, y: g.deckY + g.s * 0.05)
    let disc = CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                        width: radius * 2, height: radius * 2), transform: nil)
    fillGradient(
        context, path: disc,
        colors: [rgb(255, 204, 88), rgb(255, 148, 76), rgb(250, 84, 104)],
        from: CGPoint(x: centre.x, y: centre.y + radius),
        to: CGPoint(x: centre.x, y: centre.y - radius)
    )
    return context
}

/// The Mac mini in its current shape: a squarer aluminium block with a softly
/// rounded body, a darker top face, two front ports and the power light.
func drawMini(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    let plate = g.plate
    let miniWidth = plate.width * 0.56
    let miniHeight = plate.height * 0.225
    let mini = CGRect(
        x: plate.midX - miniWidth / 2,
        y: plate.minY + plate.height * 0.05,
        width: miniWidth,
        height: miniHeight
    )
    let miniRadius = miniHeight * 0.34
    let body = roundedRect(mini, radius: miniRadius)

    fillGradient(
        context, path: body,
        colors: [rgb(250, 251, 253), rgb(214, 219, 228), rgb(168, 176, 190)],
        from: CGPoint(x: mini.midX, y: mini.maxY),
        to: CGPoint(x: mini.midX, y: mini.minY)
    )

    // The top face, darker, so it reads as a block rather than a pill.
    let topFace = CGRect(x: mini.minX, y: mini.maxY - miniHeight * 0.26,
                         width: mini.width, height: miniHeight * 0.26)
    context.saveGState()
    context.addPath(body)
    context.clip()
    fillGradient(
        context, path: CGPath(rect: topFace, transform: nil),
        colors: [rgb(196, 202, 214), rgb(232, 236, 242)],
        from: CGPoint(x: topFace.midX, y: topFace.maxY),
        to: CGPoint(x: topFace.midX, y: topFace.minY)
    )
    context.restoreGState()

    // Two front ports, as on the current model, and the power light.
    let portY = mini.minY + miniHeight * 0.30
    let portHeight = miniHeight * 0.13
    let portWidth = mini.width * 0.075
    context.setFillColor(rgb(70, 76, 92, 0.85))
    for i in 0..<2 {
        let port = CGRect(x: mini.minX + mini.width * 0.10 + CGFloat(i) * portWidth * 1.6,
                          y: portY, width: portWidth, height: portHeight)
        context.addPath(roundedRect(port, radius: portHeight / 2))
        context.fillPath()
    }
    let ledSize = miniHeight * 0.13
    context.setFillColor(rgb(120, 240, 160))
    context.fillEllipse(in: CGRect(x: mini.maxX - mini.width * 0.12, y: portY,
                                   width: ledSize, height: ledSize))
    return context
}

/// Main cables and hangers, in warm white: pale enough to read against the sun,
/// warm enough to stay apart from the pure-white towers and deck.
func drawCables(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(rgb(255, 244, 224))

    // Side spans: from the anchorages at deck level up to each tower top, sagging.
    context.setLineWidth(g.cableWidth)
    for (anchorX, towerX) in [(g.leftX, g.towerLeftX), (g.rightX, g.towerRightX)] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: anchorX, y: g.deckY))
        path.addQuadCurve(
            to: CGPoint(x: towerX, y: g.towerTop),
            control: CGPoint(x: anchorX + (towerX - anchorX) * 0.62, y: g.deckY + (g.towerTop - g.deckY) * 0.30)
        )
        context.addPath(path)
        context.strokePath()
    }

    // Main span, sampled from the same parabola the hangers use.
    let main = CGMutablePath()
    let samples = 64
    for i in 0...samples {
        let x = g.towerLeftX + (g.towerRightX - g.towerLeftX) * CGFloat(i) / CGFloat(samples)
        let point = CGPoint(x: x, y: g.mainCableY(at: x))
        if i == 0 { main.move(to: point) } else { main.addLine(to: point) }
    }
    context.addPath(main)
    context.strokePath()

    // Few, heavy hangers: they survive the glass and tinted looks at small sizes.
    context.setLineWidth(g.cableWidth * 0.55)
    let hangers = 6
    for i in 1...hangers {
        let t = CGFloat(i) / CGFloat(hangers + 1)
        let x = g.towerLeftX + (g.towerRightX - g.towerLeftX) * t
        context.move(to: CGPoint(x: x, y: g.mainCableY(at: x)))
        context.addLine(to: CGPoint(x: x, y: g.deckY))
        context.strokePath()
    }
    return context
}

/// Towers and deck, in white: solid tapered towers with a cross-beam, and a heavy
/// deck. The shape that carries the icon at 16px.
func drawStructure(_ g: Geometry) -> CGContext {
    let context = makeContext(size: layerSize)
    context.setFillColor(rgb(255, 255, 255))

    for x in [g.towerLeftX, g.towerRightX] {
        // Tapered: wider at the base, as real towers are.
        let base = g.towerWidth, top = g.towerWidth * 0.72
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - base / 2, y: g.towerBase))
        path.addLine(to: CGPoint(x: x + base / 2, y: g.towerBase))
        path.addLine(to: CGPoint(x: x + top / 2, y: g.towerTop - top / 2))
        path.addArc(center: CGPoint(x: x, y: g.towerTop - top / 2), radius: top / 2,
                    startAngle: 0, endAngle: .pi, clockwise: false)
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    let deck = CGRect(x: g.leftX - g.deckThickness / 2, y: g.deckY - g.deckThickness / 2,
                      width: g.rightX - g.leftX + g.deckThickness, height: g.deckThickness)
    context.addPath(roundedRect(deck, radius: g.deckThickness / 2))
    context.fillPath()
    return context
}

// MARK: - Icon Composer bundle
//
// Format learned from Xcode's own "Icon Composer Icon" file template
// (Xcode.app/.../Templates/File Templates/macOS/Resource) and the key names in
// Icon Composer's frameworks, then checked by rendering with `ictool` (in Xcode's
// Icon Composer.app/Contents/Executables).

/// icon.json: a dusk gradient (indigo sky down to a warm horizon), with glass and
/// specular on the artwork so the system lights it. There is deliberately no dark
/// fill specialization: ictool ignored one, and the system's own dark treatment
/// (near-black tile, artwork kept) reads well. Groups are listed top-down: the Mac
/// mini in front, then the bridge, then the sun behind it.
let iconJSON = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.22745,0.15686,0.74510,1.00000",
          "srgb:1.00000,0.43137,0.35294,1.00000"
        ],
        "orientation" : {
          "start" : { "x" : 0.5, "y" : 0 },
          "stop" : { "x" : 0.5, "y" : 1 }
        }
      },
      "groups" : [
        {
          "name" : "Mac mini",
          "layers" : [
            { "name" : "Mac mini", "image-name" : "mac-mini.png", "glass" : true }
          ],
          "lighting" : "combined",
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "specular" : true,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        },
        {
          "name" : "Bridge",
          "layers" : [
            { "name" : "Structure", "image-name" : "bridge-structure.png", "glass" : true },
            { "name" : "Cables", "image-name" : "bridge-cables.png", "glass" : false }
          ],
          "lighting" : "individual",
          "shadow" : { "kind" : "layer-color", "opacity" : 0.35 },
          "specular" : true,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        },
        {
          "name" : "Sun",
          "layers" : [
            { "name" : "Sun", "image-name" : "sun.png", "glass" : false }
          ],
          "lighting" : "combined",
          "shadow" : { "kind" : "none", "opacity" : 0 },
          "specular" : false,
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
    write(drawSun(g), to: iconAssets.appendingPathComponent("sun.png"))
    write(drawMini(g), to: iconAssets.appendingPathComponent("mac-mini.png"))
    write(drawCables(g), to: iconAssets.appendingPathComponent("bridge-cables.png"))
    write(drawStructure(g), to: iconAssets.appendingPathComponent("bridge-structure.png"))
    try! iconJSON.write(to: iconBundle.appendingPathComponent("icon.json"),
                        atomically: true, encoding: .utf8)
    print("  AppIcon.icon — 4 layers, \(layerSize)px")
}

// MARK: - Main

print("Generating App/AppIcon.icon")
generateAppIcon()
print("Done.")
