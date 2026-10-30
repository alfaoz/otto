import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["OTTO_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["OTTO_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Setup.onLaunch()
        Notices.shared.setUp()
        Presence.start()
        Engine.shared.start()
        AutoLock.start()
        _ = Updates.shared
        let preview = (env["OTTO_PREVIEW"] ?? "").split(separator: ",").map(String.init)
        if !preview.isEmpty { Task { await Self.preview(preview, dir: env["OTTO_SNAPSHOT_DIR"]) } }
    }

    /// dev aid: OTTO_PREVIEW=main,entry,editor,new,code,settings,request,site,bypass,change,import,askdone walks through those
    /// surfaces; with OTTO_SNAPSHOT_DIR each one is written there as a PNG. card, key, note, mac show the first
    /// entry of that kind, edit-card (-key...) edits it, new-card (-key...) starts a new one.
    private static func preview(_ surfaces: [String], dir: String?) async {
        try? await Task.sleep(for: .seconds(1.5))
        let ui = UIState.shared
        let entries = Engine.shared.entries
        let pick = ProcessInfo.processInfo.environment["OTTO_PREVIEW_ENTRY"] ?? "GitHub"
        let login = entries.first { $0.name == pick } ?? entries.first { !$0.library }
        let code = entries.first { $0.library }
        // OTTO_PREVIEW_CLEAN: pictures of otto, like the website's: no "PREVIEW: " in front of the agents' reasons,
        // and a browser shows as connected
        let clean = ProcessInfo.processInfo.environment["OTTO_PREVIEW_CLEAN"] != nil
        if clean { Engine.shared.browsers = ["Google Chrome"] }
        func said(_ s: String) -> String { clean && s.hasPrefix("PREVIEW: ") ? String(s.dropFirst(9)) : s }
        func shoot(_ name: String, _ match: @MainActor (NSWindow) -> Bool = { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            guard let dir else { return }
            guard let w = NSApp.windows.first(where: { match($0) && $0.isVisible }) else {
                let all = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")/\($0.title)/\($0.isVisible)" }
                FileHandle.standardError.write("preview: no window for \(name) among \(all)\n".data(using: .utf8)!)
                return
            }
            Windows.snapshot(w, to: URL(filePath: dir).appending(path: "\(name).png"))
        }
        for s in surfaces {
            switch s {
            case "main": ui.route = .activity
            case _ where s.hasPrefix("entry:"):
                if let e = entries.first(where: { $0.name == s.dropFirst(6) }) { ui.route = .entry(e.id) }
            case "value":
                if let e = entries.first(where: { $0.kind == "value" && $0.secret }) { ui.route = .entry(e.id) }
            case "plain-value":
                if let e = entries.first(where: { $0.kind == "value" && !$0.secret }) { ui.route = .entry(e.id) }
            case "edit-value":
                if let e = entries.first(where: { $0.kind == "value" && $0.secret }) { ui.startEdit(e) }
            case "entry": if let login { ui.route = .entry(login.id) }
            case "code": if let code { ui.route = .entry(code.id) }
            case "editor": ui.startEdit(login)
            case "new": ui.startEdit(nil)
            case "card", "key", "note", "mac":
                if let e = entries.first(where: { $0.kind == s }) { ui.route = .entry(e.id) }
            case _ where s.hasPrefix("edit-"):
                if let e = entries.first(where: { $0.kind == s.dropFirst(5) }) { ui.startEdit(e) }
            case _ where s.hasPrefix("new-"):
                if let k = Kind(rawValue: String(s.dropFirst(4))) { ui.startEdit(nil, kind: k) }
            case _ where s.hasPrefix("typed-"):
                // a new entry with something typed in: typed-card, typed-card-back (the CVC field), typed-key
                let parts = s.split(separator: "-").map(String.init)
                guard parts.count >= 2, let k = Kind(rawValue: parts[1]) else { continue }
                var draft = Self.drafts[k.rawValue] ?? [:]
                if parts.count > 2, parts[2] == "back" { draft["focus"] = "cvc" }
                ui.previewDraft = draft
                ui.startEdit(nil, kind: k)
            case "settings":
                for tab in ["general", "browser", "agents", "remote", "vault"] {
                    Windows.shared.showSettings(tab: tab)
                    try? await Task.sleep(for: .seconds(1))
                    shoot("settings-\(tab)") { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") || $0.title == tab.capitalized }
                }
                continue
            case "wait": try? await Task.sleep(for: .seconds(2)); continue
            case "menubar":
                // the icon, then its panel, opened the way a click would
                let bar = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
                if let bar { shoot("menubar-icon") { $0 === bar } }
                func button(_ v: NSView?) -> NSStatusBarButton? {
                    guard let v else { return nil }
                    return v as? NSStatusBarButton ?? v.subviews.lazy.compactMap { button($0) }.first
                }
                button(bar?.contentView)?.performClick(nil)
                try? await Task.sleep(for: .seconds(1.3))
                FileHandle.standardError.write("preview: windows \(NSApp.windows.map { "\(type(of: $0))/\($0.isVisible)" })\n".data(using: .utf8)!)
                shoot("menubar") { $0 !== bar && $0.identifier?.rawValue.hasPrefix("main") != true && $0.frame.width > 200 }
                continue
            case "dock":
                // closing the main window takes otto out of the Dock, opening it brings it back
                func policy() -> String { NSApp.activationPolicy() == .regular ? "in the Dock" : "menu bar only" }
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.performClose(nil)
                try? await Task.sleep(for: .seconds(1))
                FileHandle.standardError.write("preview: after close, \(policy())\n".data(using: .utf8)!)
                Presence.showMain()
                try? await Task.sleep(for: .seconds(1))
                let shown = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
                FileHandle.standardError.write("preview: after open, \(policy()), main window \(shown ? "shown" : "missing")\n".data(using: .utf8)!)
                continue
            case "askdone":
                // answered from the phone: the save window and the Touch ID prompt for it go away by themselves
                func log(_ s: String) { FileHandle.standardError.write("preview: \(s)\n".data(using: .utf8)!) }
                func shown() -> Bool { NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("request-") == true && $0.isVisible } }
                let save = Task {
                    try? await Windows.shared.saveRequest(SaveRequest([
                        "name": "github", "site": "github.com", "agent": "claude", "ask": "preview-save",
                        "note": said("PREVIEW: this window closes by itself in a second"),
                    ]))
                }
                try? await Task.sleep(for: .seconds(1.5))
                log("save window before: \(shown() ? "shown" : "missing")")
                Windows.shared.askDone("preview-save")
                Auth.cancel(ask: "preview-save")
                let reply = await save.value
                try? await Task.sleep(for: .seconds(0.5))
                log("save window after: \(shown() ? "still shown" : "closed"), replied \(reply ?? [:])")
                let prompt = Task { await Auth.approve(reason: "PREVIEW: check that this prompt goes away by itself", ask: "preview-approve") }
                try? await Task.sleep(for: .seconds(1.5))
                Auth.cancel(ask: "preview-approve")
                log("touch id prompt replied \(await prompt.value.reply)")
                continue
            case "import": Windows.shared.showImport(); continue
            case "trash": ui.route = .trash
            case "locked":
                await Engine.shared.lock()
                ui.route = .activity
            case "unlock": await Engine.shared.unlock(reason: "PREVIEW: unlock itself"); continue
            case "limits":
                // the entry with a limit to one agent and one folder
                if let login { _ = try? await Engine.shared.upsert(["id": login.id, "agents": ["claude"], "folders": ["~/otto"]]); ui.route = .entry(login.id) }
            case "command":
                Task {
                    _ = await Windows.shared.approveCommand(CommandRequest([
                        "agent": "claude", "folder": "~/website", "verified": true,
                        "command": "sudo networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1 && dscacheutil -flushcache",
                        "why": said("PREVIEW: you asked me to switch Wi-Fi DNS to Cloudflare and flush the cache"),
                    ]))
                }
                continue
            case "command-fill":
                Task {
                    _ = await Windows.shared.approveCommand(CommandRequest([
                        "agent": "claude", "folder": "~/otto", "verified": true,
                        "command": "xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}}",
                        "blanks": [["name": "apple id"], ["name": "app-specific password", "secret": true]],
                        "why": said("PREVIEW: otto's releases get notarized with this. you make the password at account.apple.com"),
                    ]))
                }
                continue
            case "command-elsewhere":
                Task {
                    _ = await Windows.shared.approveCommand(CommandRequest([
                        "agent": "claude", "folder": "~/otto", "verified": true,
                        "command": "xcrun notarytool submit build/Otto.dmg --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}} --wait",
                        "blanks": [["name": "apple id", "saved": true, "value": "demo@example.com"], ["name": "app-specific password", "secret": true, "elsewhere": ["xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}}"]]],
                        "why": said("PREVIEW: sends the release to Apple to be notarized."),
                    ]))
                }
                continue
            case "command-saved":
                Task {
                    _ = await Windows.shared.approveCommand(CommandRequest([
                        "agent": "claude", "folder": "~/otto", "verified": true,
                        "command": "xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}}",
                        "blanks": [["name": "apple id", "saved": true, "value": "demo@example.com"], ["name": "app-specific password", "secret": true, "saved": true]],
                        "why": said("PREVIEW: otto's releases get notarized with this."),
                    ]))
                }
                continue
            case "site":
                Task {
                    _ = await Windows.shared.approveSite(SiteRequest([
                        "entry": "AWS", "entry_id": entries.first { $0.name == "AWS" }?.id ?? "", "site": "eu-north-1.signin.aws.amazon.com", "domain": "amazon.com", "known": ["signin.aws.amazon.com"],
                        "agent": "claude", "what": "login",
                        "reason": said("PREVIEW: the AWS console now signs in on a regional address, so the saved site doesn't match"),
                    ]))
                }
                continue
            case "browser":
                Task {
                    _ = await Windows.shared.approveBrowser(BrowserRequest([
                        "name": "Vivaldi", "bundle": "com.vivaldi.Vivaldi", "team": "PREVIEW00",
                        "signer": "PREVIEW Vivaldi Technologies AS", "path": "/Applications/Vivaldi.app",
                    ]))
                }
                continue
            case "change", "change-key", "change-2fa":
                // run with OTTO_NO_TOUCH_ID=1 to see the PIN version
                let change: [String: Any] = switch s {
                case "change-key": ["field": "key", "value": "sk-PREVIEW-0000000000000000000000000000000000000000", "secret": true]
                case "change-2fa": ["field": "2FA secret", "label": "from the QR code for GitHub, alfa"]
                default: ["field": "password", "value": "PREVIEW-n3w-pa55word", "secret": true]
                }
                Task {
                    _ = await Windows.shared.approveChange(ChangeRequest([
                        "entry": login?.name ?? "GitHub", "entry_id": login?.id ?? "", "sites": login?.sites ?? ["github.com"], "entry_kind": "login",
                        "agent": "codex", "action": s == "change-2fa" ? "replace its 2FA secret" : "change its \(change["field"]!)", "verified": true, "pin": true,
                        "folder": "~/otto", "change": change,
                    ]))
                }
                continue
            case "bypass":
                Task {
                    _ = await Windows.shared.consentBypass(BypassRequest([
                        "entry": "Hetzner", "entry_id": entries.first { $0.name == "Hetzner" }?.id ?? "", "sites": ["accounts.hetzner.com"], "agent": "claude", "hours": 72,
                        "reason": said("PREVIEW: you said you're travelling this weekend and want me to restart the box if it goes down"),
                    ]))
                }
                continue
            case "request":
                Task {
                    _ = try? await Windows.shared.saveRequest(SaveRequest([
                        "name": "github", "site": "github.com", "username": "alfa", "needs": ["password", "totp"],
                        "note": said("PREVIEW: your github session expired; i need to log back in to push the release"), "agent": "claude",
                    ]))
                }
                continue
            default: continue
            }
            try? await Task.sleep(for: .seconds(1.3))
            shoot(s)
            if ui.isEditing {
                ui.guardian.isDirty = { false }
                ui.doneEditing()
                // let the editor go before the next one opens, as it would between clicks
                try? await Task.sleep(for: .seconds(0.4))
            }
        }
    }

    private static let drafts: [String: [String: String]] = [
        "card": ["name": "PREVIEW card", "number": "4242424242424242", "expiry": "1234", "cvc": "123", "cardholder": "Alfa Demo", "postal_code": "34000", "sites": "amazon.com.tr"],
        "key": ["key": "OPENAI_API_KEY=\"sk-proj-PREVIEWnotarealkey000000000000\""],
    ]

    /// Quitting cuts agents off, so otto asks first. Not when the Mac is logging out, restarting or shutting
    /// down: then it just goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Prefs.askBeforeQuit, !Self.macIsQuitting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit otto?"
        alert.informativeText = "agents lose access to your logins, 2FA codes and cards until you open otto again."
        alert.addButton(withTitle: "Quit")
        // the second button answers Escape
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { Prefs.askBeforeQuit = false }
        return quit ? .terminateNow : .terminateCancel
    }

    /// The quit came from macOS logging out, restarting or shutting down (its quit event says why).
    private static var macIsQuitting: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventClass == kCoreEventClass, e.eventID == kAEQuitApplication else { return false }
        return e.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// Closing the window keeps otto running in the menu bar: agents can only use it while it's open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening otto again (the Dock, Finder, Spotlight) brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Presence.showMain() }
        return true
    }
}
