import AppKit
import ApplicationServices

/// Types a secret into the focused field of a Mac app, but only if that app is one the entry allows.
/// Keystrokes go to that app's process directly, so switching apps mid-typing can't redirect them.
@MainActor
enum Typer {
    /// `anyApp`: the entry has bypass on, so whichever app is in front gets it.
    static func type(_ text: String, allowedApps: [String], anyApp: Bool = false) throws -> String {
        guard !text.isEmpty else { throw OttoError("no_value", "nothing to type") }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            throw OttoError("permission", "otto needs Accessibility permission to type. the user has to allow otto in System Settings > Privacy & Security > Accessibility, then try again")
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else {
            throw OttoError("no_app", "can't tell which app is in front")
        }
        let name = app.localizedName ?? bundle
        guard anyApp || allowedApps.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) else {
            throw OttoError("wrong_app", "the app in front is \(name) (\(bundle)), which isn't one of this entry's apps")
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.postToPid(app.processIdentifier)
            }
            usleep(8000)
        }
        return name
    }
}
