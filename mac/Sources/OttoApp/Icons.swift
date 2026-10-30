import AppKit
import SwiftUI

/// Entry icons and a tint color taken from them. Websites: the site's own apple-touch-icon or
/// favicon, fetched from the site itself (never a third-party icon service) and cached on disk.
/// Mac apps: the app's icon.
@MainActor @Observable
final class Icons {
    static let shared = Icons()

    private(set) var images: [String: NSImage] = [:]
    private(set) var tints: [String: Color] = [:]
    @ObservationIgnored private var loading = Set<String>()
    @ObservationIgnored private var appIcons: [String: NSImage] = [:]

    private static var dir: URL { Engine.supportDir.appending(path: "icons") }

    func image(_ site: String?) -> NSImage? {
        guard let site, !site.isEmpty else { return nil }
        if let i = images[site] { return i }
        load(site)
        return nil
    }

    func app(_ bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = "app:" + bundleID
        if let i = images[key] ?? appIcons[key] { return i }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 128, height: 128)
        appIcons[key] = img
        // called while drawing: publish (and compute the tint) right after
        DispatchQueue.main.async { self.set(key, img) }
        return img
    }

    /// The icon's color when it has a clear one; otherwise a neutral grey.
    func tint(site: String?, app: String?) -> Color {
        if let site, !site.isEmpty {
            _ = image(site)
            return tints[site] ?? Self.neutral
        }
        if let app, !app.isEmpty {
            _ = self.app(app)
            return tints["app:" + app] ?? Self.neutral
        }
        return Self.neutral
    }

    func tint(_ key: String) -> Color { tint(site: key, app: nil) }

    static let neutral = Color(white: 0.6)

    private func load(_ site: String) {
        guard !loading.contains(site) else { return }
        loading.insert(site)
        let file = Self.dir.appending(path: "\(site).png")
        if let img = NSImage(contentsOf: file) {
            DispatchQueue.main.async { self.set(site, img) }
            return
        }
        guard !site.hasPrefix("127.") && site != "localhost" && site.contains(".") else { return }
        let dir = Self.dir
        Task.detached {
            guard let img = await Self.fetch(site) else { return }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? png.write(to: file)
            }
            await MainActor.run { self.set(site, img) }
        }
    }

    /// Tries the host, then its parent domain: a declared touch icon first, then whatever the
    /// page links to, then the classic favicon.
    nonisolated private static func fetch(_ site: String) async -> NSImage? {
        let labels = site.split(separator: ".")
        let root = labels.count > 2 ? labels.suffix(2).joined(separator: ".") : nil
        for host in [site, root].compactMap({ $0 }) {
            if let i = await get("https://\(host)/apple-touch-icon.png", min: 48) { return i }
            for link in await declared(host) {
                if let i = await get(link, min: 32) { return i }
            }
        }
        for host in [site, root].compactMap({ $0 }) {
            if let i = await get("https://\(host)/favicon.ico", min: 16) { return i }
        }
        return nil
    }

    nonisolated private static func get(_ s: String, min: CGFloat) async -> NSImage? {
        guard let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data) else { return nil }
        let px = img.representations.map { CGFloat($0.pixelsWide) }.max() ?? img.size.width
        return max(px, img.size.width) >= min ? img : nil
    }

    /// Icon links from the site's home page, best first (touch icons, then the largest sizes).
    nonisolated private static func declared(_ host: String) async -> [String] {
        guard let url = URL(string: "https://\(host)/") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) else { return [] }
        let base = resp.url ?? url
        var found: [(score: Int, url: String)] = []
        let tags = html.matches(of: try! Regex("<link\\b[^>]*>").ignoresCase())
        for t in tags {
            let tag = String(html[t.range])
            func attr(_ name: String) -> String? {
                let r = try! Regex("\(name)\\s*=\\s*[\"']([^\"']+)[\"']").ignoresCase()
                return tag.firstMatch(of: r).flatMap { $0.output[1].substring.map(String.init) }
            }
            guard let rel = attr("rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attr("href"), let abs = URL(string: href, relativeTo: base)?.absoluteString else { continue }
            if href.lowercased().hasSuffix(".svg") { continue }
            let size = attr("sizes").flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            found.append((rel.contains("apple-touch") ? 1000 + size : size, abs))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private func set(_ key: String, _ img: NSImage) {
        images[key] = img
        // grey icons (GitHub, Vercel...) get a neutral wash rather than a made-up color
        tints[key] = Self.dominant(img) ?? Self.neutral
    }

    /// The icon's own color: its most common clearly colored hue, ignoring white, black and grey,
    /// so Cloudflare's orange cloud on white and AWS's navy behind a white logo both count. Bright,
    /// vivid pixels weigh more than dark ones. nil when there's too little color.
    private static func dominant(_ img: NSImage) -> Color? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        // hue buckets of 15°: weight, hue as a vector (it wraps around red), saturation
        let k = 24
        var weight = [Double](repeating: 0, count: k), x = weight, y = weight, sat = weight
        var opaque = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            opaque += 1
            let c = NSColor(red: Double(px[i]) / 255 / a, green: Double(px[i + 1]) / 255 / a, blue: Double(px[i + 2]) / 255 / a, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            guard s > 0.3, b > 0.15 else { continue }
            let w = s * b
            let j = min(Int(h * Double(k)), k - 1)
            weight[j] += w
            x[j] += w * cos(h * 2 * .pi)
            y[j] += w * sin(h * 2 * .pi)
            sat[j] += w * s
        }
        // the strongest run of three neighboring buckets, so a color on a bucket edge isn't split
        let around = { (j: Int) in [(j + k - 1) % k, j, (j + 1) % k] }
        let sum = { (v: [Double], j: Int) in around(j).reduce(0) { $0 + v[$1] } }
        guard let best = (0..<k).max(by: { sum(weight, $0) < sum(weight, $1) }) else { return nil }
        let w = sum(weight, best)
        guard w >= 3, w / Double(max(opaque, 1)) >= 0.01 else { return nil }
        var hue = atan2(sum(y, best), sum(x, best)) / (2 * .pi)
        if hue < 0 { hue += 1 }
        // soften: the wash sits behind text, so keep it bright and only moderately saturated
        return Color(nsColor: NSColor(hue: hue, saturation: min(sum(sat, best) / w, 0.55), brightness: 0.85, alpha: 1))
    }
}

/// The site's (or app's) icon in a rounded square, or its first letter.
struct SiteIcon: View {
    let site: String?
    var app: String?
    let name: String
    var size: CGFloat = 28

    var body: some View {
        if let img = Icons.shared.image(site) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else if let img = Icons.shared.app(app) {
            // app icons bring their own shape and margin
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 1.18, height: size * 1.18)
                .frame(width: size, height: size)
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(
                    LinearGradient(colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                )
        }
    }
}

enum AgentStyle {
    /// lookups of a browser's icon, misses too: this runs for every row
    @MainActor private static var browserIcons: [String: NSImage?] = [:]

    /// The browser's own icon, for a line about it ("Google Chrome"). nil for anything else.
    @MainActor static func browserIcon(_ name: String) -> NSImage? {
        if let known = browserIcons[name] { return known }
        let icon = KnownBrowser.all.first { $0.name == name || $0.appName == name }?.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        browserIcons[name] = icon
        return icon
    }

    private static var logos: [String: NSImage] = [:]

    /// The agent's own mark (Resources/agents, from Simple Icons), drawn in one color; nil for agents
    /// without one, which show their initial instead.
    @MainActor static func logo(_ agent: String) -> NSImage? {
        let name: String
        switch agent.lowercased() {
        case "claude": name = "claude"
        case "codex": name = "codex"
        case "gemini": name = "gemini"
        case "cursor": name = "cursor"
        default: return nil
        }
        if let i = logos[name] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "agents"),
              let i = NSImage(contentsOf: url) else { return nil }
        i.isTemplate = true
        logos[name] = i
        return i
    }

    static func color(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(red: 0.45, green: 0.78, blue: 0.62)
        case "gemini": Color(red: 0.47, green: 0.6, blue: 0.95)
        case "cursor": Color(white: 0.85)
        case "you": Color(white: 0.7)
        default: Color(red: 0.7, green: 0.62, blue: 0.95)
        }
    }
}
