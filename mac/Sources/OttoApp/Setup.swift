import AppKit
import ServiceManagement

/// The user's choices in Settings that only the app reads (UserDefaults keys and their defaults).
enum Prefs {
    static let menuBarKey = "showMenuBar"
    static let askBeforeQuitKey = "askBeforeQuit"
    /// "never", "sleep" (the Mac sleeps or its screen locks), or minutes away with no agent using otto
    static let autoLockKey = "autoLock"

    static var autoLock: String { UserDefaults.standard.string(forKey: autoLockKey) ?? "never" }

    static var askBeforeQuit: Bool {
        get { UserDefaults.standard.object(forKey: askBeforeQuitKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askBeforeQuitKey) }
    }
}

/// Things kept in place on every launch: the browser helper registration, a stable copy of the
/// extension to load in a browser, and the `otto` command on PATH.
@MainActor
enum Setup {
    static var extensionDir: URL { Engine.supportDir.appending(path: "extension") }

    static func onLaunch() {
        if Engine.devHome != nil { return }
        copyExtension()
        registerBrowserHelper()
        linkCLI()
        refreshSkills()
    }

    /// Codex and opencode keep a copy of otto's skill; keep it current with this version.
    static func refreshSkills() {
        guard let bin = Engine.binaryURL else { return }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["connect", "--refresh"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func copyExtension() {
        guard let bundled = Bundle.main.resourceURL?.appending(path: "extension") else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled.path) else { return }
        // the whole folder, icons included
        if fm.contentsEqual(atPath: bundled.path, andPath: extensionDir.path) { return }
        try? fm.removeItem(at: extensionDir)
        try? fm.createDirectory(at: Engine.supportDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: bundled, to: extensionDir)
    }

    static func registerBrowserHelper() {
        // a throwaway copy leaves the real browsers' connection to otto alone
        guard Engine.devHome == nil, let bin = Engine.binaryURL else { return }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["install-browser"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// ~/.local/bin/otto -> the binary in this bundle (only if that folder exists and the name is free or ours).
    static func linkCLI() {
        guard let bin = Engine.binaryURL else { return }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        let link = dir.appending(path: "otto")
        guard fm.fileExists(atPath: dir.path) else { return }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == bin.path { return }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            return
        }
        try? fm.createSymbolicLink(at: link, withDestinationURL: bin)
    }

    /// Claude Code lists its installed plugins here; "otto@<marketplace>" means ours is in.
    static var claudePluginInstalled: Bool {
        let f = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/plugins/installed_plugins.json")
        guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let plugins = j["plugins"] as? [String: Any] else { return false }
        return plugins.keys.contains { $0.hasPrefix("otto@") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { _ = setLaunchAtLogin(newValue) }
    }

    /// What went wrong, for the user to see (nil: it's as asked).
    static func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return "couldn't change it: \(error.localizedDescription)"
        }
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "macOS wants you to allow otto in System Settings → General → Login Items."
        }
        return nil
    }

    static func copy(_ s: String, concealed: Bool = false, clearAfter: TimeInterval? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        if concealed {
            // clipboard managers skip items marked like this
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        if let t = clearAfter {
            let count = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if pb.changeCount == count { pb.clearContents() }
            }
        }
    }
}
