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
// Design ("Pepper shield"): a Big Sur-style squircle in midnight navy with a
// faint red glow, a glossy red pimento shaped like a heraldic shield (guarded,
// privileged access) with gold edging, a keyhole punched through it, and a
// green calyx with a curled stem on top. At 32 px and below the shield fills
// the squircle, the keyhole grows, and the rim, stem and secondary highlights
// are dropped.

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
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: CGColor, dx: CGFloat = 0) {
        setShadow(offset: CGSize(width: dx * S, height: dy * S), blur: blur * S, color: color)
    }
    func fill(_ path: CGPath, _ color: CGColor) { addPath(path); setFillColor(color); fillPath() }
    func linear(_ path: CGPath, _ g: CGGradient, _ a: CGPoint, _ b: CGPoint) {
        with { addPath(path); clip(); drawLinearGradient(g, start: a, end: b, options: extend) }
    }
    func radial(_ path: CGPath, _ g: CGGradient, _ c: CGPoint, _ r: CGFloat) {
        with { addPath(path); clip(); drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation]) }
    }
    /// A shadow cast inwards from the path's edge.
    func innerShadow(_ path: CGPath, _ color: CGColor, blur: CGFloat, dy: CGFloat = 0, dx: CGFloat = 0) {
        with {
            addPath(path); clip()
            let ring = CGMutablePath()
            ring.addRect(path.boundingBox.insetBy(dx: -400, dy: -400))
            ring.addPath(path)
            shadow(dy, blur, color, dx: dx)
            addPath(ring); setFillColor(rgb(0x000000)); fillPath(using: .evenOdd)
        }
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

/// `p` scaled by `s` (`s * sx` horizontally), rotated by `r` and moved to `c`.
func place(_ p: CGPath, at c: CGPoint, scale s: CGFloat, sx: CGFloat = 1, rotate r: CGFloat = 0) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: r).scaledBy(x: s * sx, y: s)
    return p.copy(using: &t)!
}

/// `path` with its corners rounded off: outset by half of `width` with round joins.
func rounded(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).union(path)
}

/// A pimento shaped like a heraldic shield: the pepper's two lobed shoulders
/// with a dip for the stem, straight-ish flanks, and a blunt point. Unit space
/// (y up): about 1.0 wide, y from -0.60 to +0.51.
let shieldPepperUnit: CGPath = {
    let p = CGMutablePath()
    p.move(to: pt(0, 0.40))
    p.addCurve(to: pt(0.46, 0.42), control1: pt(0.10, 0.52), control2: pt(0.34, 0.54))
    p.addCurve(to: pt(0.50, 0.04), control1: pt(0.52, 0.34), control2: pt(0.50, 0.20))
    p.addCurve(to: pt(0.04, -0.58), control1: pt(0.50, -0.26), control2: pt(0.30, -0.46))
    p.addQuadCurve(to: pt(-0.04, -0.58), control: pt(0, -0.62))
    p.addCurve(to: pt(-0.50, 0.04), control1: pt(-0.30, -0.46), control2: pt(-0.50, -0.26))
    p.addCurve(to: pt(-0.46, 0.42), control1: pt(-0.50, 0.20), control2: pt(-0.52, 0.34))
    p.addCurve(to: pt(0, 0.40), control1: pt(-0.34, 0.54), control2: pt(-0.10, 0.52))
    p.closeSubpath()
    return p
}()

/// A keyhole: a round head of radius `r` at `c` over a slot that widens to
/// `foot` at `length` below the centre, corners softened.
func keyhole(center c: CGPoint, radius r: CGFloat, length l: CGFloat, foot: CGFloat) -> CGPath {
    let head = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    let slot = CGMutablePath()
    slot.move(to: pt(c.x - r * 0.42, c.y - r * 0.2))
    slot.addLine(to: pt(c.x + r * 0.42, c.y - r * 0.2))
    slot.addLine(to: pt(c.x + foot / 2, c.y - l))
    slot.addLine(to: pt(c.x - foot / 2, c.y - l))
    slot.closeSubpath()
    return rounded(head.union(slot), r * 0.18)
}

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

/// A soft white specular streak: an elongated ellipse, tilted by `angle`,
/// fading from top to bottom, clipped to `clip`.
func highlight(_ ctx: CGContext, clip: CGPath, center c: CGPoint, w: CGFloat, h: CGFloat, angle: CGFloat, alpha: CGFloat) {
    let e = place(CGPath(ellipseIn: CGRect(x: -0.5, y: -0.5, width: 1, height: 1), transform: nil), at: c, scale: h, sx: w / h, rotate: angle)
    ctx.with {
        ctx.addPath(clip); ctx.clip()
        let up = pt(c.x - sin(angle) * h * 0.5, c.y + cos(angle) * h * 0.5)
        let down = pt(c.x + sin(angle) * h * 0.5, c.y - cos(angle) * h * 0.5)
        ctx.linear(e, gradient([(0, rgb(0xFFFFFF, alpha)), (1, rgb(0xFFFFFF, 0))]), up, down)
    }
}

// MARK: - Drawing (in a 1024 × 1024 design space)

let background = gradient([
    (0.0, rgb(0x34407A)),   // midnight navy (top)
    (0.55, rgb(0x1A2150)),
    (1.0, rgb(0x0B0F2E)),   // near-black (bottom)
])
let flesh = gradient([(0, rgb(0xFF6A4D)), (0.45, rgb(0xE8202E)), (1, rgb(0x8E0A22))])
let green = gradient([(0, rgb(0x9BE15D)), (0.5, rgb(0x46B04A)), (1, rgb(0x1E6E35))])
let keyholeDark = gradient([(0, rgb(0x0B0F2E)), (1, rgb(0x2A2F5A))])

func drawIcon(in ctx: CGContext, pixels: Int) {
    // At 16 and 32 px the rim, stem and fine highlights turn to mush: drop
    // them, enlarge the shield and its keyhole.
    let small = pixels <= 32

    // Body with a soft drop shadow (Big Sur grid: 824 pt body, 100 pt margin),
    // the background gradient, a faint top-left sheen and a hairline edge.
    let body = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.with {
        ctx.shadow(-10, 24, rgb(0x000000, 0.30))
        ctx.fill(body, rgb(0x1A2150))
    }
    ctx.linear(body, background, pt(330, 924), pt(694, 100))
    ctx.radial(body, gradient([(0, rgb(0xFFFFFF, 0.16)), (1, rgb(0xFFFFFF, 0))]), pt(330, 900), 640)
    if !small {
        ctx.with {
            ctx.addPath(body); ctx.clip()
            ctx.addPath(body); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(6); ctx.strokePath()
        }
        // A faint red glow behind the shield.
        ctx.radial(body, gradient([(0, rgb(0xFF5A4A, 0.30)), (1, rgb(0xFF5A4A, 0))]), pt(512, 470), 400)
    }

    // The shield-shaped pepper: drop shadow, glossy red flesh lit from the top
    // left, an inner shadow along its lower right edge, and a gold rim.
    let s: CGFloat = small ? 640 : 530
    let c = small ? pt(512, 470) : pt(512, 476)
    let shield = place(shieldPepperUnit, at: c, scale: s)
    ctx.with {
        ctx.shadow(-20, 40, rgb(0x000000, small ? 0.3 : 0.5))
        ctx.fill(shield, rgb(0xC81A2A))
    }
    let box = shield.boundingBox
    ctx.radial(shield, flesh, pt(box.minX + box.width * 0.36, box.minY + box.height * 0.72), max(box.width, box.height) * 0.85)
    if !small {
        ctx.innerShadow(shield, rgb(0x4A0010, 0.55), blur: 46, dy: 18, dx: -10)
        ctx.with {
            ctx.addPath(shield); ctx.clip()
            ctx.addPath(shield); ctx.setLineWidth(18)
            ctx.setStrokeColor(rgb(0xFFB36B, 0.55)); ctx.strokePath()
        }
    }

    // The keyhole, punched through to a dark interior; larger when small, and
    // bolder still at 16 px, where it is little more than a dark slot.
    let hole = pixels <= 16
        ? keyhole(center: pt(512, c.y + 40), radius: 104, length: 240, foot: 150)
        : small
        ? keyhole(center: pt(512, c.y + 30), radius: 82, length: 200, foot: 120)
        : keyhole(center: pt(512, c.y + 40), radius: 62, length: 170, foot: 86)
    ctx.linear(hole, keyholeDark, pt(0, hole.boundingBox.maxY), pt(0, hole.boundingBox.minY))
    if !small {
        ctx.innerShadow(hole, rgb(0x000000, 0.9), blur: 16, dy: -10)
        // The hole's lit lower lip.
        ctx.with {
            ctx.addPath(hole); ctx.setLineWidth(6); ctx.setStrokeColor(rgb(0xFF8A70, 0.5))
            ctx.translateBy(x: 0, y: -3); ctx.strokePath()
        }
        highlight(ctx, clip: shield, center: pt(c.x - s * 0.30, c.y + s * 0.12), w: 64, h: 250, angle: 0.18, alpha: 0.85)
        highlight(ctx, clip: shield, center: pt(c.x + s * 0.30, c.y + s * 0.33), w: 34, h: 90, angle: -1.1, alpha: 0.5)
    } else if pixels > 16 {
        highlight(ctx, clip: shield, center: pt(c.x - s * 0.30, c.y + s * 0.10), w: 80, h: 240, angle: 0.18, alpha: 0.6)
    }

    // A short stem curling up to the right, then the calyx over the dip.
    let top = c.y + 0.40 * s
    if !small {
        let stem = CGMutablePath()
        stem.move(to: pt(512, top + 10))
        stem.addCurve(to: pt(582, top + 128), control1: pt(510, top + 80), control2: pt(540, top + 120))
        let stemShape = stem.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.with { ctx.shadow(-4, 8, rgb(0x000000, 0.4)); ctx.fill(stemShape, rgb(0x2F8F3E)) }
        ctx.linear(stemShape, green, pt(480, 0), pt(600, 0))
    }
    let r: CGFloat = small ? 170 : 150
    let cap = calyx(center: pt(512, top + 4), radius: r)
    ctx.with {
        ctx.shadow(-6, 12, rgb(0x3A0010, small ? 0 : 0.45))
        ctx.fill(cap, rgb(0x2F8F3E))
    }
    ctx.linear(cap, green, pt(512, top + 4 + r * 0.5), pt(512, top + 4 - r * 0.5))
}

/// The menu bar glyph: the pepper shield's silhouette, black on transparent
/// (macOS tints template images for the menu bar), with a short, thick stem
/// from the top dip and the keyhole cut out. No squircle, colour or calyx: at
/// 18 pt only the silhouette and one cut-out read, a calyx line turns it into
/// an acorn, and a thin curled stem into an apple.
func drawMenuBarGlyph(in ctx: CGContext, pixels: Int) {
    let black = rgb(0x000000)
    // One point of the 18 pt glyph, in design units.
    let u: CGFloat = 1024 / 18
    let c = pt(9 * u, 8.4 * u)
    let s = 13 * u
    ctx.fill(place(shieldPepperUnit, at: c, scale: s), black)

    // The stem: a stub from the top dip, leaning slightly right.
    let top = pt(c.x, c.y + 0.40 * s)
    let stem = CGMutablePath()
    stem.move(to: pt(top.x, top.y - 0.5 * u))
    stem.addLine(to: pt(top.x + 0.4 * u, top.y + 2.4 * u))
    ctx.fill(stem.copy(strokingWithWidth: 2.2 * u, lineCap: .round, lineJoin: .round, miterLimit: 10), black)

    // The keyhole, cut out.
    ctx.with {
        ctx.setBlendMode(.clear)
        ctx.addPath(keyhole(center: pt(c.x, c.y + 1.0 * u), radius: 2.3 * u, length: 5.0 * u, foot: 2.4 * u))
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
