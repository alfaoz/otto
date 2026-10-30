import AppKit
import UserNotifications

/// A notification for each use the user didn't approve right then (Auto, bypass, an earlier Touch ID yes),
/// with Stop: otto then refuses everything from that agent's session until it exits. Uses of one entry by
/// one session within a minute share a notification ("claude signed in to GitHub (password, 2FA code)").
@MainActor
final class Notices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notices()

    private struct Recent {
        var at: Date
        var whats: [String]
        var hows: [String]
    }

    private var recent: [String: Recent] = [:]
    private var asked = false

    /// notifications need a real app bundle (not a bare `swift build` binary)
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let stop = UNNotificationAction(identifier: "stop", title: "Stop", options: [.destructive])
        let here = UNNotificationAction(identifier: "here", title: "Answer on This Mac", options: [.foreground])
        let quiet = UNNotificationAction(identifier: "quiet", title: "Don’t Notify for This One", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "use", actions: [stop, quiet], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ask", actions: [here], intentIdentifiers: []),
        ])
    }

    /// From the service's "ask" event: an agent sent the user a link because they said they're away. Nothing
    /// pops up on the Mac; clicking this answers it here instead (the window, or Touch ID).
    func ask(_ d: [String: Any]) {
        guard let id = d["ask"] as? String else { return }
        let content = UNMutableNotificationContent()
        content.title = d["title"] as? String ?? "an agent is waiting for you"
        content.body = d["kind"] as? String == "save"
            ? "you're away, so it sent you a link to save it from your phone. click to do it here instead."
            : "you're away, so it sent you a link to answer from your phone. click to answer here instead."
        if Engine.devHome != nil { content.subtitle = "test copy" }
        content.categoryIdentifier = "ask"
        content.userInfo = ["ask": id]
        post(UNNotificationRequest(identifier: "ask-\(id)", content: content, trigger: nil))
    }

    /// Answered (on the phone or here) or ran out: its notification goes.
    func askDone(_ id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: ["ask-\(id)"])
        center?.removePendingNotificationRequests(withIdentifiers: ["ask-\(id)"])
    }

    /// From the service's "used" event: who, which entry, what they did with it, where.
    func used(_ d: [String: Any]) {
        guard center != nil else { return }
        let thread = d["thread"] as? String ?? ""
        let entry = d["entry"] as? String ?? "an entry"
        let who = d["who"] as? String ?? d["agent"] as? String ?? "an agent"
        let folder = d["folder"] as? String
        let how = d["how"] as? String ?? "used"
        let key = "\(thread)|\(d["entry_id"] as? String ?? entry)"
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value.at) < 60 }
        var r = recent[key] ?? Recent(at: now, whats: [], hows: [])
        r.at = now
        for w in d["what"] as? [String] ?? [] where !r.whats.contains(w) { r.whats.append(w) }
        if !r.hows.contains(how) { r.hows.append(how) }
        recent[key] = r

        let content = UNMutableNotificationContent()
        content.title = Self.title(who: who, entry: entry, kind: d["kind"] as? String ?? "login", hows: r.hows, whats: r.whats, place: d["place"] as? String)
        content.body = Self.body(how: how, place: d["place"] as? String, folder: folder, bypass: d["bypass"] as? Bool == true)
        if Engine.devHome != nil { content.subtitle = "test copy" }
        content.categoryIdentifier = "use"
        content.threadIdentifier = thread
        content.userInfo = ["thread": thread, "who": who, "folder": folder ?? "", "entry_id": d["entry_id"] as? String ?? ""]
        // the same identifier replaces the earlier notification instead of stacking another
        post(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    /// From the service's "remote_notice" event: a device was paired, or wrong PINs turned remote off.
    func remote(_ d: [String: Any]) {
        let device = d["device"] as? String ?? "a device"
        let content = UNMutableNotificationContent()
        switch d["kind"] as? String {
        case "paired":
            content.title = "otto paired \(device) for remote"
            content.body = "it can save logins now, and approve uses with your PIN. remove it in otto's settings if that wasn't you."
        case "locked":
            content.title = "remote is off"
            content.body = "5 wrong PINs from \(device). set the PIN again in otto to turn it back on."
        default:
            return
        }
        if Engine.devHome != nil { content.subtitle = "test copy" }
        content.userInfo = ["open": "remote"]
        post(UNNotificationRequest(identifier: "remote-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Whether macOS shows otto's notifications: nil while otto hasn't asked yet.
    func allowed() async -> Bool? {
        guard let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return nil
        case .denied: return false
        default: return true
        }
    }

    /// Asks macOS now, instead of with the first notification (which the user might then miss).
    @discardableResult
    func ask() async -> Bool? {
        guard let center else { return false }
        asked = true
        _ = try? await center.requestAuthorization(options: [.alert])
        return await allowed()
    }

    /// Once the vault is open: if otto never asked, ask, so the first use without a prompt has somewhere to show.
    func askIfNeverAsked() {
        Task { if await allowed() == nil { await ask() } }
    }

    private func post(_ request: UNNotificationRequest) {
        guard let center else { return }
        Task {
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert])
            }
            try? await center.add(request)
        }
    }

    static func title(who: String, entry: String, kind: String, hows: [String], whats: [String], place: String?) -> String {
        let login = whats.contains("password") || whats.contains("username")
        let code = whats.contains("2FA code")
        let parts = whats.joined(separator: ", ")
        if login && code { return "\(who) signed in to \(entry) (\(parts))" }
        if hows.count > 1 { return "\(who) used \(entry) (\(parts))" }
        switch hows.first {
        case "got": return "\(who) got \(entry)’s 2FA code"
        case "filled" where code: return "\(who) filled \(entry)’s 2FA code"
        case "filled": return "\(who) filled \(entry)"
        case "typed": return "\(who) typed \(entry)’s \(parts)"
        case "handed": return "\(who) handed \(entry)’s \(parts) to \(place ?? "a command")"
        case "ran": return "\(who) ran a command as root"
        default: return "\(who) used \(entry)"
        }
    }

    static func body(how: String, place: String?, folder: String?, bypass: Bool) -> String {
        var parts: [String] = []
        if let place, !place.isEmpty {
            switch how {
            case "typed": parts.append("into \(place)")
            case "ran": parts.append(place)
            case "handed": break
            default: parts.append("on \(place)")
            }
        }
        if let folder, !folder.isEmpty { parts.append("in \(folder)") }
        let text = parts.joined(separator: ", ")
        guard bypass else { return text }
        return text.isEmpty ? "bypass" : "\(text) (bypass)"
    }

    // MARK: delegate

    /// show it even while otto is the app in front
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let thread = info["thread"] as? String ?? ""
        let who = info["who"] as? String ?? ""
        let folder = info["folder"] as? String ?? ""
        let open = info["open"] as? String
        let ask = info["ask"] as? String
        let entryID = info["entry_id"] as? String ?? ""
        let action = response.actionIdentifier
        await MainActor.run {
            if let ask, action == "here" || action == UNNotificationDefaultActionIdentifier {
                Task { try? await Engine.shared.call("ask_here", ["ask": ask]) }
            } else if open == "remote" {
                Windows.shared.showSettings(tab: "remote")
            } else if action == "quiet" {
                Task { _ = try? await Engine.shared.upsert(["id": entryID, "quiet": true]) }
            } else if action == "stop" {
                var args: [String: Any] = ["thread": thread, "who": who]
                if !folder.isEmpty { args["folder"] = folder }
                Task { try? await Engine.shared.call("cut_off", args) }
            } else if action == UNNotificationDefaultActionIdentifier {
                UIState.shared.go(.activity)
                UIState.bringMainWindowForward()
            }
        }
    }
}
