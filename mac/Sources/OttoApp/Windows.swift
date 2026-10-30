import AppKit
import SwiftUI

/// Regular windows for agent save requests, import and onboarding.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()

    private var open: [String: NSWindow] = [:]
    private var onClose: [String: () -> Void] = [:]
    private var guards: [String: CloseGuard] = [:]
    private var closingAnyway = Set<String>()
    /// save and change windows for requests the phone can answer too: ask id -> window id
    private var asks: [String: String] = [:]

    var hasOpenWindows: Bool { !open.isEmpty }

    /// `closesIn`: seconds until the service stops waiting for this window. It shows a timer, and closes then,
    /// because an answer after that would go nowhere. One the phone can answer too goes when the service says.
    private func show<V: View>(id: String, title: String, floating: Bool = false, closesIn: TimeInterval? = nil, closeGuard: CloseGuard? = nil, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) {
        if let w = open[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        // the window follows the content's height (top edge fixed). letting NSHostingController drive the
        // window size under a transparent titlebar can loop forever ("more Update Constraints passes than views").
        // the content sits below the transparent titlebar (AppKit keeps the window at least that tall anyway);
        // windows reach their backgrounds up under it with ignoresSafeArea
        let ref = WindowRef()
        let deadline = closesIn.map { Date.now.addingTimeInterval($0) }
        let root = content()
            .overlay(alignment: .topTrailing) {
                // in the titlebar, across from the window's buttons
                if let deadline { ClosesIn(deadline: deadline).padding(.trailing, 14).offset(y: -24) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in ref.fit(size) }
            .tint(.primary)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        ref.window = w
        w.title = title
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // any real size, so the titlebar's height can be read off it
        w.setFrame(NSRect(x: 0, y: 0, width: 480, height: 400), display: false)
        // measuring lays the content out once and reports its size to `ref`
        let fitting = host.sizeThatFits(in: NSSize(width: 4000, height: 4000))
        if let size = ref.measured { ref.fit(size) } else { w.setContentSize(fitting) }
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = floating ? .floating : .normal
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.center()
        open[id] = w
        if let onClose { self.onClose[id] = onClose }
        if let closeGuard { guards[id] = closeGuard }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let closesIn {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(closesIn))
                if self.open[id] === w, !self.asks.values.contains(id) { self.close(id) }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["OTTO_SNAPSHOT_DIR"] {
            let delay = Double(ProcessInfo.processInfo.environment["OTTO_SNAPSHOT_DELAY"] ?? "") ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.snapshot(w, to: URL(filePath: dir).appending(path: "\(id).png")) }
        }
    }

    /// When a window closes, from what the service said: a little before it stops waiting, so a yes at the
    /// last second still counts. A request the phone can answer too just shows the time it has left. Without
    /// a time (a preview), `usual`.
    private func closing(_ expiresIn: Double?, ask: String? = nil, usual: Double) -> Double {
        guard let expiresIn else { return usual }
        return ask != nil ? expiresIn : max(expiresIn - 10, 5)
    }

    /// dev aid: the window's own pixels. A process may always capture its own windows, so this needs
    /// no screen recording permission; the window server's copy includes glass, which cacheDisplay can't draw.
    static func snapshot(_ w: NSWindow, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // the menu bar's own windows can have numbers that aren't window server ids: draw those instead
        if let number = UInt32(exactly: w.windowNumber), number > 0, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(sym, to: CreateImage.self)
            // including window | ignore framing + best resolution
            if let img = create(.null, 1 << 3, number, 1 << 0 | 1 << 3)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = w.contentView?.superview ?? w.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Close after a save or delete: nothing to ask about.
    func close(_ id: String) {
        closingAnyway.insert(id)
        open[id]?.close()
    }

    /// Close like the window's close button: asks first if there are unsaved changes.
    func dismiss(_ id: String) {
        open[id]?.performClose(nil)
    }

    func windowShouldClose(_ w: NSWindow) -> Bool {
        guard let id = w.identifier?.rawValue, !closingAnyway.contains(id), let g = guards[id], g.isDirty() else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your changes?"
        alert.informativeText = "are you sure you want to leave without saving? what you typed here will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Keep Editing")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: w) { r in
            switch r {
            case .alertFirstButtonReturn: g.save?()
            case .alertSecondButtonReturn: self.close(id)
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        open.removeValue(forKey: id)
        guards.removeValue(forKey: id)
        closingAnyway.remove(id)
        onClose.removeValue(forKey: id)?()
    }

    /// Shows the agent's request and waits for the user. Closing the window counts as "not now".
    func saveRequest(_ r: SaveRequest) async throws -> [String: Any] {
        let id = "request-\(UUID().uuidString)"
        if let ask = r.ask { asks[ask] = id }
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (patch: [String: Any]?) in
                guard !done else { return }
                done = true
                if let patch { c.resume(returning: ["saved": true, "patch": patch]) } else { c.resume(returning: ["saved": false]) }
            }
            NSSound(named: "Tink")?.play()
            let g = CloseGuard()
            show(id: id, title: "Save for \(r.agent)", floating: true, closesIn: closing(r.expiresIn, ask: r.ask, usual: 890), closeGuard: g, onClose: {
                if let ask = r.ask { self.asks[ask] = nil }
                finish(nil)
            }) {
                SaveRequestView(r: r, finish: { patch in
                    if let patch {
                        finish(patch)
                        self.close(id)
                    } else {
                        self.dismiss(id)
                    }
                }, closeGuard: g)
            }
        }
    }

    /// An agent wants to change a stored secret: the window shows what it would become, then Touch ID (or
    /// the PIN). Closing it counts as no.
    func approveChange(_ r: ChangeRequest) async -> [String: Any] {
        let id = "change-\(UUID().uuidString)"
        if let ask = r.ask { asks[ask] = id }
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (reply: [String: Any]) in
                guard !done else { return }
                done = true
                c.resume(returning: reply)
            }
            NSSound(named: "Tink")?.play()
            show(id: id, title: "Change \(r.entry)", floating: true, closesIn: closing(r.expiresIn, ask: r.ask, usual: 290), onClose: {
                if let ask = r.ask { self.asks[ask] = nil }
                finish(["approved": false, "declined": true])
            }) {
                ChangeRequestView(r: r) { reply in
                    finish(reply)
                    self.close(id)
                }
            }
        }
    }

    /// An agent wants to run a command only the user should decide on: the window shows it, then Touch ID.
    /// Closing it counts as no.
    func approveCommand(_ r: CommandRequest) async -> [String: Any] {
        let id = "command-\(UUID().uuidString)"
        if let ask = r.ask { asks[ask] = id }
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (reply: [String: Any]) in
                guard !done else { return }
                done = true
                c.resume(returning: reply)
            }
            NSSound(named: "Tink")?.play()
            show(id: id, title: "Run a command", floating: true, closesIn: closing(r.expiresIn, ask: r.ask, usual: r.blanks.isEmpty ? 290 : 890), onClose: {
                if let ask = r.ask { self.asks[ask] = nil }
                finish(["approved": false, "declined": true])
            }) {
                CommandRequestView(r: r) { reply in
                    finish(reply)
                    self.close(id)
                }
            }
        }
    }

    /// The phone answered the request (or it ran out): its save window goes away without asking about
    /// what was typed in it. The service ignores the "not saved" this gives back.
    func askDone(_ ask: String) {
        guard let id = asks.removeValue(forKey: ask) else { return }
        close(id)
    }

    /// An agent wants to use an entry on a new domain. Closing the window counts as no.
    func approveSite(_ r: SiteRequest) async -> [String: Any] {
        let id = "site-\(UUID().uuidString)"
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (remember: Bool?) in
                guard !done else { return }
                done = true
                c.resume(returning: ["approved": remember != nil, "remember": remember ?? false])
            }
            NSSound(named: "Tink")?.play()
            show(id: id, title: "New site for \(r.entry)", floating: true, closesIn: closing(r.expiresIn, usual: 290), onClose: { finish(nil) }) {
                SiteApprovalView(r: r) { remember in
                    finish(remember)
                    self.close(id)
                }
            }
        }
    }

    /// Bypass for one entry: the user ticks the sentence and confirms with Touch ID. Closing counts as no.
    func consentBypass(_ r: BypassRequest) async -> [String: Any] {
        let id = "bypass-\(UUID().uuidString)"
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (consent: [String: Any]?) in
                guard !done else { return }
                done = true
                c.resume(returning: consent ?? ["granted": false])
            }
            if r.agent != nil { NSSound(named: "Tink")?.play() }
            // asked by an agent, whose call gives up; opened by the user, it waits for them
            show(id: id, title: "Bypass for \(r.entry)", floating: true, closesIn: r.agent != nil ? closing(r.expiresIn, usual: 290) : nil, onClose: { finish(nil) }) {
                BypassConsentView(r: r) { consent in
                    finish(consent)
                    self.close(id)
                }
            }
        }
    }

    /// `otto sudo` needs the Mac password and otto doesn't have it yet. Closing counts as not now.
    func macPassword(_ r: MacPasswordRequest) async -> [String: Any] {
        let id = "mac-password"
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (password: String?) in
                guard !done else { return }
                done = true
                c.resume(returning: password.map { ["saved": true, "password": $0] } ?? ["saved": false])
            }
            NSSound(named: "Tink")?.play()
            show(id: id, title: "Mac Password", floating: true, closesIn: closing(r.expiresIn, usual: 260), onClose: { finish(nil) }) {
                MacPasswordRequestView(r: r) { password in
                    finish(password)
                    self.close(id)
                }
            }
        }
    }

    /// A browser otto doesn't know wants to connect. Closing counts as not now.
    func approveBrowser(_ r: BrowserRequest) async -> [String: Any] {
        let id = "browser-\(r.bundle)"
        return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            var done = false
            let finish = { (ok: Bool) in
                guard !done else { return }
                done = true
                c.resume(returning: ["approved": ok])
            }
            NSSound(named: "Tink")?.play()
            show(id: id, title: "Allow \(r.name)", floating: true, closesIn: closing(r.expiresIn, usual: 170), onClose: { finish(false) }) {
                BrowserApprovalView(r: r) { ok in
                    finish(ok)
                    self.close(id)
                }
            }
        }
    }

    func showImport() {
        show(id: "import", title: "Import") { ImportView { self.close("import") } }
    }

    func showSettings(tab: String? = nil) {
        SettingsOpener.open(tab)
    }

    func showOnboarding() {
        show(id: "onboarding", title: "Welcome to otto") { OnboardingView { self.close("onboarding") } }
    }
}

private final class WindowRef {
    weak var window: NSWindow?
    /// the content's size, also when it was measured before the window existed
    var measured: CGSize?

    func fit(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        measured = size
        guard let w = window else { return }
        // the content sits below the transparent titlebar, which is part of the frame
        let bar = w.frame.height > 50 ? w.frame.height - w.contentLayoutRect.height : 0
        let target = NSRect(x: 0, y: 0, width: size.width, height: size.height + bar)
        guard abs(target.height - w.frame.height) > 0.5 || abs(target.width - w.frame.width) > 0.5 else { return }
        var f = w.frame
        f.origin.y += f.height - target.height
        f.size = target.size
        w.setFrame(f, display: true)
    }
}

/// Lets a window ask its SwiftUI content whether closing would lose edits.
@MainActor
final class CloseGuard {
    var isDirty: () -> Bool = { false }
    var save: (() -> Void)?
}

/// Opens the Settings scene (on a given tab). SwiftUI only hands out the action inside a view,
/// so the main window passes it here.
@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?

    static func open(_ tab: String?) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settings.tab") }
        NSApp.activate()
        if let action {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
