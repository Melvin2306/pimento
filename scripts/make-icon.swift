#!/usr/bin/env swift
// Renders the Pimento app icon with CoreGraphics: every PNG size of the macOS
// iconset, then AppIcon.icns via iconutil. The drawing below is the icon's
// source; re-run after changing it:
//
//   swift scripts/make-icon.swift
//
// Output: Assets/AppIcon.iconset/*.png and Assets/AppIcon.icns, plus the menu
// bar glyph Assets/MenuBarIcon.png and MenuBarIcon@2x.png (18 pt).
//
// Design ("Countdown pepper"): a Big Sur-style squircle in deep wine, a flat
// two-tone pimento with an up-chevron cut out of it (elevated privilege),
// inside an amber countdown arc with 70 % left (the elevation is temporary).
// At 32 px and below the arc is dropped and the pepper fills the squircle; at
// 16 px the chevron goes too.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

/// Device pixels per design unit. Shadow offsets and blurs ignore the CTM, so
/// they are given in design units and multiplied by this.
var S: CGFloat = 1

extension CGContext {
    func with(_ body: () -> Void) { saveGState(); body(); restoreGState() }
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: CGColor) {
        setShadow(offset: CGSize(width: 0, height: dy * S), blur: blur * S, color: color)
    }
    func fill(_ path: CGPath, _ color: CGColor) { addPath(path); setFillColor(color); fillPath() }
    func linear(_ path: CGPath, _ g: CGGradient, _ a: CGPoint, _ b: CGPoint) {
        with { addPath(path); clip(); drawLinearGradient(g, start: a, end: b, options: extend) }
    }
    func radial(_ path: CGPath, _ g: CGGradient, _ c: CGPoint, _ r: CGFloat) {
        with { addPath(path); clip(); drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation]) }
    }
}

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Apple's app-icon shape is close to a superellipse |x|^n + |y|^n = 1 with n ≈ 5.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = pt(rect.midX + x * rect.width / 2, rect.midY + y * rect.height / 2)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func place(_ p: CGPath, at c: CGPoint, scale s: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s)
    return p.copy(using: &t)!
}

/// A pimento: broad rounded shoulders with a dip for the stem, tapering to a
/// blunt bottom with two gentle lobes. Unit space (y up): about 1.0 wide,
/// y from -0.53 to +0.47.
let pepperUnit: CGPath = {
    let p = CGMutablePath()
    p.move(to: pt(0, 0.36))
    p.addCurve(to: pt(0.50, 0.16), control1: pt(0.14, 0.50), control2: pt(0.48, 0.52))
    p.addCurve(to: pt(0.30, -0.42), control1: pt(0.53, -0.10), control2: pt(0.44, -0.30))
    p.addCurve(to: pt(0, -0.48), control1: pt(0.22, -0.50), control2: pt(0.08, -0.54))
    p.addCurve(to: pt(-0.30, -0.42), control1: pt(-0.08, -0.54), control2: pt(-0.22, -0.50))
    p.addCurve(to: pt(-0.50, 0.16), control1: pt(-0.44, -0.30), control2: pt(-0.53, -0.10))
    p.addCurve(to: pt(0, 0.36), control1: pt(-0.48, 0.52), control2: pt(-0.14, 0.50))
    p.closeSubpath()
    return p
}()

/// Calyx: a flattened rosette of `n` rounded sepals around the stem, their
/// tips drooping over the pepper's shoulders.
func calyx(center c: CGPoint, radius r: CGFloat, n: Int = 5, flatten: CGFloat = 0.42) -> CGPath {
    let path = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let lobe = pow(abs(cos(CGFloat(n) * (t - .pi / 2) / 2)), 2.2)
        let k = 0.74 + 0.26 * lobe
        let x = cos(t) * r * k
        let y = sin(t) * r * k * flatten - 0.16 * r * lobe * (1 - abs(sin(t)) * 0.4) - (sin(t) < 0 ? 0.10 * r * abs(sin(t)) : 0)
        let p = pt(c.x + x, c.y + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// An up-chevron centred on `c`, `w` wide and `h` tall (centre line), drawn
/// with round caps and joins at `stroke` width.
func chevron(center c: CGPoint, width w: CGFloat, height h: CGFloat, stroke: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: pt(c.x - w / 2, c.y - h / 2))
    p.addLine(to: pt(c.x, c.y + h / 2))
    p.addLine(to: pt(c.x + w / 2, c.y - h / 2))
    return p.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// The stem: from the pepper's top dip, curling up and to the right.
func stem(from top: CGPoint, scale s: CGFloat, width: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: top)
    p.addCurve(to: pt(top.x + s * 0.20, top.y + s * 0.30),
               control1: pt(top.x - s * 0.02, top.y + s * 0.20),
               control2: pt(top.x + s * 0.08, top.y + s * 0.30))
    return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// MARK: - Drawing (in a 1024 × 1024 design space)

let background = gradient([
    (0.0, rgb(0x7A1838)),   // wine (top)
    (0.5, rgb(0x4A0C26)),
    (1.0, rgb(0x1E0612)),   // near-black (bottom)
])
let amber = gradient([(0, rgb(0xFFD25A)), (0.5, rgb(0xFF9A3C)), (1, rgb(0xFF5E3A))])
let flesh = gradient([(0, rgb(0xFF7A4A)), (1, rgb(0xF2303A))])

func drawIcon(in ctx: CGContext, pixels: Int) {
    // At 16 and 32 px the arc turns to mush: drop it and enlarge the pepper.
    let small = pixels <= 32

    // Body with a soft drop shadow (Big Sur grid: 824 pt body, 100 pt margin),
    // the background gradient, a faint top-left sheen and a hairline edge.
    let body = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.with {
        ctx.shadow(-10, 24, rgb(0x000000, 0.30))
        ctx.fill(body, rgb(0x4A0C26))
    }
    ctx.linear(body, background, pt(330, 924), pt(694, 100))
    ctx.radial(body, gradient([(0, rgb(0xFFFFFF, 0.14)), (1, rgb(0xFFFFFF, 0))]), pt(330, 900), 640)
    if !small {
        ctx.with {
            ctx.addPath(body); ctx.clip()
            ctx.addPath(body); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(6); ctx.strokePath()
        }
    }

    // Countdown arc: a faint full track, and an amber arc with a glow from
    // 12 o'clock running clockwise, 70 % of the way round.
    if !small {
        let center = pt(512, 506), r: CGFloat = 306
        ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(44); ctx.strokePath()
        let start = CGFloat.pi / 2, end = start - 2 * .pi * 0.70
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: true)
        let arcShape = arc.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.with { ctx.shadow(0, 30, rgb(0xFF8A3C, 0.55)); ctx.fill(arcShape, rgb(0xFF9A3C)) }
        ctx.linear(arcShape, amber, pt(512, 830), pt(300, 300))
    }

    // Flat two-tone pepper: lit left half, shaded right half.
    let s: CGFloat = small ? 620 : 400
    let pc = small ? pt(512, 450) : pt(512, 478)
    let pepper = place(pepperUnit, at: pc, scale: s)
    ctx.with {
        ctx.shadow(-10, 26, rgb(0x000000, small ? 0 : 0.45))
        ctx.fill(pepper, rgb(0xF2403A))
    }
    ctx.linear(pepper, flesh, pt(0, pepper.boundingBox.maxY), pt(0, pepper.boundingBox.minY))
    let shade = CGMutablePath()
    shade.move(to: pt(pc.x + s * 0.02, pc.y + s * 0.6))
    shade.addCurve(to: pt(pc.x + s * 0.02, pc.y - s * 0.7),
                   control1: pt(pc.x + s * 0.20, pc.y + s * 0.1),
                   control2: pt(pc.x + s * 0.18, pc.y - s * 0.3))
    shade.addLine(to: pt(pc.x + s, pc.y - s * 0.7))
    shade.addLine(to: pt(pc.x + s, pc.y + s * 0.6))
    shade.closeSubpath()
    ctx.with { ctx.addPath(pepper); ctx.clip(); ctx.fill(shade, rgb(0xB0102E, 0.45)) }

    // Up-chevron cut out of the pepper (elevation); at 16 px it only muddies.
    if pixels > 16 {
        let chev = chevron(center: pt(pc.x, pc.y - s * (small ? 0.04 : 0.05)),
                           width: s * (small ? 0.48 : 0.40), height: s * (small ? 0.24 : 0.20),
                           stroke: s * (small ? 0.15 : 0.105))
        ctx.fill(chev, rgb(0xFFF1E0))
    }

    // Stem curling up to the right, then a flat calyx cap with a shaded half.
    let top = pt(pc.x, pc.y + s * 0.36)
    ctx.fill(stem(from: top, scale: s, width: s * (small ? 0.14 : 0.10)), rgb(0x3FA34A))
    let cap = calyx(center: pt(top.x, top.y + s * 0.01), radius: s * (small ? 0.30 : 0.27))
    ctx.fill(cap, rgb(0x5CC24D))
    ctx.with {
        ctx.addPath(cap); ctx.clip()
        ctx.fill(CGPath(rect: CGRect(x: top.x + 4, y: 0, width: 1024, height: 1024), transform: nil), rgb(0x2E8B3A, 0.6))
    }
}

/// The menu bar glyph: the pepper's silhouette with its stem, black on
/// transparent (macOS tints template images for the menu bar), the up-chevron
/// cut out. No squircle, calyx or arc: at 18 pt only the silhouette and one
/// cut-out read, and the countdown is the text next to it.
func drawMenuBarGlyph(in ctx: CGContext, pixels: Int) {
    let black = rgb(0x000000)
    let retina = pixels > 18
    let s: CGFloat = 750
    let pc = pt(512, 430)
    ctx.fill(place(pepperUnit, at: pc, scale: s), black)

    // A slim stem from the top dip, curling up to the right.
    let top = pt(pc.x, pc.y + s * 0.30)
    let stemPath = CGMutablePath()
    stemPath.move(to: top)
    stemPath.addCurve(to: pt(top.x + s * 0.20, top.y + s * 0.31),
                      control1: pt(top.x - s * 0.02, top.y + s * 0.20),
                      control2: pt(top.x + s * 0.07, top.y + s * 0.31))
    ctx.fill(stemPath.copy(strokingWithWidth: retina ? 100 : 112, lineCap: .round, lineJoin: .round, miterLimit: 10), black)

    // The chevron, cut out.
    ctx.with {
        ctx.setBlendMode(.clear)
        ctx.addPath(chevron(center: pt(pc.x, pc.y - s * 0.04), width: s * 0.44, height: s * 0.22,
                            stroke: retina ? 116 : 120))
        ctx.fillPath()
    }
}

func render(pixels: Int, draw: (CGContext, Int) -> Void = { drawIcon(in: $0, pixels: $1) }) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    S = CGFloat(pixels) / 1024
    ctx.scaleBy(x: S, y: S)
    draw(ctx, pixels)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: - Main

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(render(pixels: points * factor), to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

for (name, pixels) in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)] {
    try writePNG(render(pixels: pixels) { drawMenuBarGlyph(in: $0, pixels: $1) }, to: assets.appendingPathComponent(name))
}
print("Wrote \(iconset.path), AppIcon.icns and MenuBarIcon.png")
