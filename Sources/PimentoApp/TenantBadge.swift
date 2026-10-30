import AppKit
import PimentoCore
import SwiftUI

/// A tenant's icon: its fetched logo when *Fetch tenant logos* is on and one
/// was found, else its monogram (initials on a colour from the tenant ID).
/// Gets the model as a value, so it works in the menu bar and in tables too.
struct TenantBadge: View {
    let model: AppModel
    let tenant: TenantInfo
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: TenantBadgeImage.image(for: tenant, logo: model.tenantLogos.image(for: tenant), size: size))
            .frame(width: size, height: size)
            // Asks for the logo once per tenant and domain list; again when the setting is turned on.
            .task(id: "\(TenantLogoStore.requestKey(tenant))|\(model.prefs.fetchTenantLogos)") {
                model.tenantLogos.request(tenant)
            }
            .accessibilityHidden(true)
    }
}

/// Draws badges with AppKit, so the same image works in SwiftUI views and
/// in menus (the Settings and History pickers), at any screen scale.
enum TenantBadgeImage {
    static func image(for tenant: TenantInfo, logo: CGImage?, size: CGFloat) -> NSImage {
        let monogram = TenantMonogram(tenant: tenant)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.24
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            if let logo {
                // A light plate: transparent logos stay visible in dark mode.
                NSColor.white.setFill()
                shape.fill()
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSGraphicsContext.current?.imageInterpolation = .high
                NSGraphicsContext.current?.cgContext.draw(logo, in: aspectFit(logo, in: rect.insetBy(dx: size * 0.08, dy: size * 0.08)))
                NSGraphicsContext.restoreGraphicsState()
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
                edge.lineWidth = 0.5
                NSColor(white: 0, alpha: 0.18).setStroke()
                edge.stroke()
            } else {
                color(monogram.color.rgb).setFill()
                shape.fill()
                let font = NSFont.systemFont(ofSize: size * (monogram.initials.count > 1 ? 0.42 : 0.52), weight: .semibold)
                let text = NSAttributedString(string: monogram.initials, attributes: [.font: font, .foregroundColor: NSColor.white])
                let width = text.size().width
                // Centre the capitals: baseline half a cap height below the middle.
                let baseline = rect.midY - font.capHeight / 2
                text.draw(at: NSPoint(x: rect.midX - width / 2, y: baseline + font.descender))
            }
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    static func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return rect }
        let scale = min(rect.width / w, rect.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Fetched tenant logos for the views: loads them in the background, at
/// most four at a time, only for tenants a view shows (`TenantBadge` asks
/// when it appears), and only while the setting is on outside demo mode.
@MainActor
@Observable
final class TenantLogoStore {
    /// Decoded thumbnails by tenant ID.
    private(set) var images: [String: CGImage] = [:]
    /// Mirrors `Preferences.fetchTenantLogos`.
    private(set) var enabled = false
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var pending: [TenantInfo] = []
    @ObservationIgnored private var running = 0
    /// The fetches under way, cancelled by `clear()` so that none sends more once the setting is off.
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextTask = 0
    /// Bumped by `clear()`: answers to earlier requests are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored let service = TenantLogoService(cache: TenantLogoCache(directory: TenantLogoCache.defaultDirectory()))

    static let maxConcurrent = 4
    /// Pixels on the long side of a decoded logo (badges are at most 24 pt).
    static let thumbnailPixels = 96

    var isAllowed: Bool { TenantLogoService.isAllowed(enabled: enabled, demo: AppRuntime.isDemo) }

    func image(for tenant: TenantInfo) -> CGImage? {
        isAllowed ? images[tenant.id] : nil
    }

    /// One request per tenant and domain list: a tenant first seen without
    /// its domains (before the list loads) is asked about again with them.
    static func requestKey(_ tenant: TenantInfo) -> String {
        ([tenant.id, tenant.defaultDomain ?? ""] + tenant.domains).joined(separator: " ")
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        // Off: forget the logos, on disk too.
        if !on { clear() }
    }

    func request(_ tenant: TenantInfo) {
        guard isAllowed, requested.insert(Self.requestKey(tenant)).inserted else { return }
        pending.append(tenant)
        pump()
    }

    /// Fetches `tenants` again, ignoring the cache; the current logos stay
    /// until their replacements arrive.
    func refresh(_ tenants: [TenantInfo]) {
        guard isAllowed else { return }
        service.cache.clear()
        requested.removeAll()
        pending.removeAll()
        for tenant in tenants { request(tenant) }
    }

    /// Deletes every downloaded logo; badges show monograms until they are
    /// shown again (and, with the setting on, fetched again).
    func clear() {
        generation += 1
        images = [:]
        requested.removeAll()
        pending.removeAll()
        for task in tasks.values { task.cancel() }
        let cache = service.cache
        Task.detached(priority: .utility) { cache.clear() }
    }

    private func pump() {
        while running < Self.maxConcurrent, !pending.isEmpty {
            let tenant = pending.removeFirst()
            running += 1
            let service = service, generation = generation, demo = AppRuntime.isDemo, pixels = Self.thumbnailPixels
            let id = nextTask
            nextTask += 1
            tasks[id] = Task.detached(priority: .utility) { [weak self] in
                let logo = await service.logo(for: tenant, enabled: true, demo: demo)
                let image = logo.flatMap { LogoImageCheck.thumbnail($0.data, maxPixels: pixels) }
                await self?.finish(id, tenantId: tenant.id, image: image, generation: generation)
            }
        }
    }

    private func finish(_ task: Int, tenantId: String, image: CGImage?, generation: Int) {
        running -= 1
        tasks[task] = nil
        if generation == self.generation, isAllowed {
            images[tenantId] = image
        } else {
            // Cleared or turned off while this one was under way: do not keep what it cached.
            service.cache.remove(tenantId: tenantId)
        }
        pump()
    }
}
