import AppKit
import SwiftUI

/// otto's mark, from the same outlines as the app icon (tools/icon.swift): "ot" over "to" in IBM Plex Mono
/// SemiBold. The menu bar shows the bare letters; while an agent is using otto they sit in the full tile.
enum OttoMark {
    // font units, y down, baseline at 0, advance 600
    private static let o = "M300 12Q241 12 194.5 -7Q148 -26 115.5 -61Q83 -96 65.5 -146Q48 -196 48 -258Q48 -320 65.5 -370Q83 -420 115.5 -455Q148 -490 194.5 -509Q241 -528 300 -528Q358 -528 405 -509Q452 -490 484.5 -455Q517 -420 534.5 -370Q552 -320 552 -258Q552 -196 534.5 -146Q517 -96 484.5 -61Q452 -26 405 -7Q358 12 300 12ZM300 -86Q355 -86 387 -119.5Q419 -153 419 -218V-298Q419 -363 387 -396.5Q355 -430 300 -430Q245 -430 213 -396.5Q181 -363 181 -298V-218Q181 -153 213 -119.5Q245 -86 300 -86Z"
    private static let t = "M335 0Q261 0 226 -39Q191 -78 191 -140V-415H41V-516H143Q174 -516 187 -528.5Q200 -541 200 -573V-698H319V-516H529V-415H319V-101H529V0Z"
    /// the letters' box in font units: x 41...1152, y -698...772
    private static let box = CGRect(x: 41, y: -698, width: 1111, height: 1470)

    /// The four letters, `height` tall, centred on `center` (y up).
    static func letters(height: CGFloat, center: CGPoint, into p: CGMutablePath = CGMutablePath()) -> CGMutablePath {
        let k = height / box.height
        for (glyph, gx, gy) in [(o, 0.0, 0.0), (t, 600, 0), (t, 0, 760), (o, 600, 760)] as [(String, CGFloat, CGFloat)] {
            append(glyph, to: p) { x, y in
                CGPoint(x: center.x + (x + gx - box.midX) * k, y: center.y - (y + gy - box.midY) * k)
            }
        }
        return p
    }

    /// The menu bar icon: the letters at rest, the tile with the letters cut out while an agent is using
    /// otto, faded while otto can't be used. Both fill the same square, so nothing beside it moves.
    static func menuBar(active: Bool, faded: Bool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            let path = CGMutablePath()
            if active {
                let tile = rect.insetBy(dx: 0.5, dy: 0.5)
                path.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
                _ = letters(height: tile.height * 0.8, center: mid, into: path)
            } else {
                _ = letters(height: side - 1, center: mid, into: path)
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(faded ? 0.4 : 1).cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "otto"
        return image
    }

    /// Appends svg path data (absolute M/L/H/V/Q/Z only) to `p`, through `map` from font units to points.
    private static func append(_ d: String, to p: CGMutablePath, map: (CGFloat, CGFloat) -> CGPoint) {
        var spaced = ""
        for ch in d { spaced += ch.isLetter ? " \(ch) " : ch == "-" ? " -" : String(ch) }
        let tokens = spaced.split(separator: " ").map(String.init)
        var i = 0, cmd: Character = "M", x: CGFloat = 0, y: CGFloat = 0
        func num() -> CGFloat { i += 1; return CGFloat(Double(tokens[i - 1]) ?? 0) }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter {
                cmd = c; i += 1
                if c == "Z" { p.closeSubpath(); continue }
            }
            switch cmd {
            case "M": x = num(); y = num(); p.move(to: map(x, y)); cmd = "L"
            case "L": x = num(); y = num(); p.addLine(to: map(x, y))
            case "H": x = num(); p.addLine(to: map(x, y))
            case "V": y = num(); p.addLine(to: map(x, y))
            case "Q":
                let cx = num(), cy = num(); x = num(); y = num()
                p.addQuadCurve(to: map(x, y), control: map(cx, cy))
            default: return
            }
        }
    }
}

/// otto lives in the menu bar. It's in the Dock only while one of its own windows is open: closing the main
/// window with the x keeps it running (agents need it), just out of the way.
@MainActor
enum Presence {
    /// SwiftUI's way to open the main window, picked up from the first view that has it
    static var openMain: OpenWindowAction?

    static func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                if let w = n.object as? NSWindow, counts(w) { inDock(true) }
            }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow, counts(w) else { return }
                // the closing window still reads as visible here
                let others = NSApp.windows.contains { $0 !== w && counts($0) && ($0.isVisible || $0.isMiniaturized) }
                if !others { inDock(false) }
            }
        }
    }

    /// Brings the main window up (reopening it if it was closed), with otto back in the Dock.
    static func showMain() {
        inDock(true)
        if let open = openMain {
            open(id: "main")
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// Windows that put otto in the Dock: the main window, Settings, import and onboarding. Approval prompts
    /// and the menu bar panel don't.
    private static func counts(_ w: NSWindow) -> Bool {
        let id = w.identifier?.rawValue ?? ""
        return id.hasPrefix("main") || id.contains("Settings") || id == "import" || id == "onboarding"
    }

    private static func inDock(_ yes: Bool) {
        let policy: NSApplication.ActivationPolicy = yes ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if yes { NSApp.activate() }
    }
}

/// The menu bar icon. Watches the engine, so it lights up while an agent is using otto.
struct MenuBarLabel: View {
    @State private var engine = Engine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let busy = engine.live.values.contains { $0.agent != "you" }
        Image(nsImage: OttoMark.menuBar(active: busy, faded: engine.state != .ready))
            .onAppear { if Presence.openMain == nil { Presence.openMain = openWindow } }
    }
}

/// What opens from the menu bar icon: whether otto is on, what an agent is doing right now, which entries
/// have bypass on, the last few things agents did, and the way back into the app.
struct MenuBarPanel: View {
    @State private var engine = Engine.shared
    @Environment(\.openWindow) private var openWindow

    private var now: Activity? { engine.live.values.filter { $0.agent != "you" }.max { $0.ts < $1.ts } }
    private var bypassed: [Entry] { engine.entries.filter { $0.activeBypass != nil }.sorted { $0.name < $1.name } }
    private var recent: [Activity] { Array(engine.activity.filter { $0.agent != "you" }.sorted { $0.ts > $1.ts }.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if let now {
                NowRow(activity: now)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if engine.state == .ready {
                if engine.remote?.locked == true { RemoteLockedRow { settings("remote") } }
                if !bypassed.isEmpty { BypassSection(entries: bypassed) { open($0) } }
                SectionTitle("Recent")
                if recent.isEmpty {
                    Text("nothing yet. what agents do with otto shows up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                } else {
                    ForEach(recent) { a in RecentRow(activity: a) { open(entry(a)) } }
                }
            }
            Divider().padding(.horizontal, 14).padding(.vertical, 6)
            if engine.state == .locked {
                PanelButton(title: "Unlock otto") { Task { await engine.unlock(reason: "unlock itself") } }
            } else if engine.state == .ready {
                PanelButton(title: "Lock otto") { Task { await engine.lock() } }
            }
            PanelButton(title: "Open otto") { open(nil) }
            PanelButton(title: "Settings…", shortcut: "⌘,") { settings(nil) }
            PanelButton(title: "Quit otto", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .frame(width: 320)
        .animation(.snappy, value: now?.id)
        .onAppear { if Presence.openMain == nil { Presence.openMain = openWindow } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("otto").font(.headline)
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var status: (text: String, color: Color) {
        switch engine.state {
        case .starting: return ("starting", .secondary)
        case .needsKey: return ("needs your recovery key", .orange)
        case .failed: return ("couldn't start", .red)
        case .locked: return ("locked", .orange)
        case .ready:
            let mine = engine.entries.filter { !$0.library && $0.kindValue != .value }
            let usable = mine.filter { $0.access != "never" }.count
            return ("on, agents can use \(usable) of \(mine.count)", .green)
        }
    }

    private func entry(_ a: Activity) -> Entry? {
        guard let n = a.entry else { return nil }
        return engine.entries.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    private func settings(_ tab: String?) {
        dismiss()
        NSApp.activate()
        Windows.shared.showSettings(tab: tab)
    }

    private func open(_ e: Entry?) {
        dismiss()
        if let e { UIState.shared.go(.entry(e.id)) }
        Presence.showMain()
    }

    /// closes the panel (it's the key window while it's open)
    private func dismiss() {
        NSApp.windows.first { String(describing: type(of: $0)).contains("MenuBarExtra") && $0.isVisible }?.close()
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

/// An agent using otto right now.
private struct NowRow: View {
    let activity: Activity

    var body: some View {
        let tint = AgentStyle.color(activity.agent)
        HStack(spacing: 8) {
            LiveDot(color: tint)
            Text("\(Text(activity.agent).fontWeight(.semibold)) \(activity.verb)")
                .lineLimit(1)
            if let e = activity.entry { Text(e).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            Text("now").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The entries with bypass on, folded behind their count so a long list doesn't stretch the panel.
private struct BypassSection: View {
    let entries: [Entry]
    let open: (Entry) -> Void
    @State private var expanded = false

    var body: some View {
        HoverRow(action: { withAnimation(.snappy) { expanded.toggle() } }) {
            HStack(spacing: 6) {
                Text("Bypass on").foregroundStyle(.secondary)
                Text("\(entries.count)").monospacedDigit().foregroundStyle(.orange)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.top, 3)
        .accessibilityLabel("Bypass on for \(entries.count) \(entries.count == 1 ? "entry" : "entries")")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        if expanded {
            ForEach(entries) { e in BypassRow(entry: e) { open(e) } }
        }
    }
}

private struct BypassRow: View {
    let entry: Entry
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 10) {
                EntryIcon(kind: entry.kindValue, card: entry.card, site: entry.sites.first, app: entry.apps.first, name: entry.name, size: 20)
                Text(entry.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(until).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var until: String {
        guard let u = entry.activeBypass?.until else { return "until you turn it off" }
        let today = Calendar.current.isDateInToday(u)
        return "until " + u.formatted(today ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Wrong PINs turned remote off: only setting the PIN again at the Mac turns it back on.
private struct RemoteLockedRow: View {
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 20, height: 20)
                Text("remote is off: too many wrong PINs").lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }
}

private struct RecentRow: View {
    let activity: Activity
    let action: () -> Void
    @State private var engine = Engine.shared

    private var entry: Entry? {
        guard let n = activity.entry else { return nil }
        return engine.entries.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    var body: some View {
        let a = activity
        HoverRow(action: action) {
            HStack(spacing: 10) {
                AgentAvatar(agent: a.agent, size: 22, failed: a.failed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(a.agent).fontWeight(.semibold)) \(a.verb)")
                        .lineLimit(1)
                    if let n = a.entry {
                        HStack(spacing: 5) {
                            EntryIcon(kind: entry?.kindValue ?? .login, card: entry?.card, site: entry?.sites.first, app: entry?.apps.first, name: n, size: 13)
                            Text(entry?.name ?? n).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(when(a.ts)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(d) { return "yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }
}

private struct PanelButton: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 1)
        }
    }
}

/// A row that lights up under the pointer, like a menu item but quieter.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}
