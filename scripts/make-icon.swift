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
// Design: a Big Sur-style squircle with a warm pimento-red gradient, a white
// shield with an upward arrow cut out of it (elevated privilege), inside a
// countdown ring (the elevation is temporary).

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

/// Apple's app-icon shape is close to a superellipse |x|^n + |y|^n = 1 with n ≈ 5.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// Shield outline centred on `c`, `w` wide and `h` tall (y axis points up).
func shield(center c: CGPoint, width w: CGFloat, height h: CGFloat) -> CGPath {
    let hw = w / 2, top = c.y + h * 0.5, bottom = c.y - h * 0.5
    let shoulder = top - h * 0.11
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: top))
    path.addCurve(to: CGPoint(x: c.x + hw, y: shoulder),
                  control1: CGPoint(x: c.x + hw * 0.35, y: top - h * 0.07),
                  control2: CGPoint(x: c.x + hw * 0.75, y: shoulder + h * 0.01))
    path.addLine(to: CGPoint(x: c.x + hw, y: c.y + h * 0.02))
    path.addCurve(to: CGPoint(x: c.x, y: bottom),
                  control1: CGPoint(x: c.x + hw, y: c.y - h * 0.26),
                  control2: CGPoint(x: c.x + hw * 0.55, y: c.y - h * 0.42))
    path.addCurve(to: CGPoint(x: c.x - hw, y: c.y + h * 0.02),
                  control1: CGPoint(x: c.x - hw * 0.55, y: c.y - h * 0.42),
                  control2: CGPoint(x: c.x - hw, y: c.y - h * 0.26))
    path.addLine(to: CGPoint(x: c.x - hw, y: shoulder))
    path.addCurve(to: CGPoint(x: c.x, y: top),
                  control1: CGPoint(x: c.x - hw * 0.75, y: shoulder + h * 0.01),
                  control2: CGPoint(x: c.x - hw * 0.35, y: top - h * 0.07))
    path.closeSubpath()
    return path
}

/// Upward arrow: triangular head plus stem, centred on `c`.
func upArrow(center c: CGPoint, width w: CGFloat, height h: CGFloat, stem: CGFloat) -> CGPath {
    let top = c.y + h * 0.5, bottom = c.y - h * 0.5
    let headBase = top - w * 0.62
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: top))
    path.addLine(to: CGPoint(x: c.x + w / 2, y: headBase))
    path.addLine(to: CGPoint(x: c.x + stem / 2, y: headBase))
    path.addLine(to: CGPoint(x: c.x + stem / 2, y: bottom))
    path.addLine(to: CGPoint(x: c.x - stem / 2, y: bottom))
    path.addLine(to: CGPoint(x: c.x - stem / 2, y: headBase))
    path.addLine(to: CGPoint(x: c.x - w / 2, y: headBase))
    path.closeSubpath()
    return path
}

// MARK: - Drawing (in a 1024 × 1024 design space)

let background = gradient([
    (0.0, rgb(0xFF8A4C)),   // warm orange (top)
    (0.45, rgb(0xF2404A)),  // pimento red
    (1.0, rgb(0xB3134F)),   // deep crimson (bottom)
])

func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    // At 16 and 32 px the ring turns to mush: drop it and enlarge the shield.
    let small = pixels <= 32

    // Body with a soft drop shadow (Big Sur grid: 824 pt body, 100 pt margin).
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = squircle(in: bodyRect)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0xF2404A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(background, start: CGPoint(x: 330, y: 924), end: CGPoint(x: 694, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Gentle top-left sheen.
    let sheen = gradient([(0, rgb(0xFFFFFF, 0.28)), (1, rgb(0xFFFFFF, 0))])
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 330, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    // Hairline inner edge for definition on light backgrounds.
    if !small {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(body)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
        ctx.setLineWidth(6)
        ctx.strokePath()
        ctx.restoreGState()
    }

    let center = CGPoint(x: 512, y: 508)

    // Countdown ring: a faint full track, and a bright arc from 12 o'clock
    // running clockwise, about three-quarters of the way round.
    if !small {
        let ringRadius: CGFloat = 292
        ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
        ctx.setLineWidth(42)
        ctx.strokePath()
        let start = CGFloat.pi / 2
        ctx.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: start - 2 * .pi * 0.72, clockwise: true)
        ctx.setStrokeColor(rgb(0xFFFFFF))
        ctx.setLineWidth(42)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // Shield.
    let shieldSize = small ? CGSize(width: 500, height: 590) : CGSize(width: 326, height: 384)
    let shieldCenter = CGPoint(x: center.x, y: small ? center.y - 12 : center.y - 4)
    let shieldPath = shield(center: shieldCenter, width: shieldSize.width, height: shieldSize.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x5A0020, small ? 0 : 0.35))
    ctx.addPath(shieldPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    // Round the shield's shoulders by stroking it in the same colour.
    ctx.addPath(shieldPath)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.strokePath()
    // Faint vertical shading on the shield.
    ctx.saveGState()
    ctx.addPath(shieldPath)
    ctx.clip()
    let shieldShade = gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0xFFD9D4, 0.85))])
    ctx.drawLinearGradient(shieldShade,
                           start: CGPoint(x: 0, y: shieldCenter.y + shieldSize.height / 2),
                           end: CGPoint(x: 0, y: shieldCenter.y - shieldSize.height / 2), options: [])
    ctx.restoreGState()

    // Arrow, cut out of the shield: filled with the background gradient.
    // Small sizes get a squatter arrow with a wider head so it stays an arrow.
    let arrow = small
        ? upArrow(center: CGPoint(x: shieldCenter.x, y: shieldCenter.y + 30), width: 340, height: 340, stem: 120)
        : upArrow(center: CGPoint(x: shieldCenter.x, y: shieldCenter.y + 14), width: 184, height: 226, stem: 66)
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(22)
    ctx.replacePathWithStrokedPath()
    ctx.addPath(arrow)
    ctx.clip()
    ctx.drawLinearGradient(background, start: CGPoint(x: 330, y: 924), end: CGPoint(x: 694, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// The menu bar glyph: the same shield and arrow, black on transparent (macOS
/// tints template images for the menu bar), the arrow cut out. No squircle and
/// no ring: at 18 pt only the silhouette reads.
func drawMenuBarGlyph(in ctx: CGContext, pixels: Int) {
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let center = CGPoint(x: 512, y: 500)
    let shieldPath = shield(center: center, width: 760, height: 900)
    ctx.addPath(shieldPath)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.addPath(shieldPath)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(40)
    ctx.setStrokeColor(rgb(0x000000))
    ctx.strokePath()
    ctx.setBlendMode(.clear)
    ctx.addPath(upArrow(center: CGPoint(x: center.x, y: center.y + 40), width: 470, height: 540, stem: 170))
    ctx.fillPath()
}

func render(pixels: Int, draw: (CGContext, Int) -> Void = { drawIcon(in: $0, pixels: $1) }) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
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
