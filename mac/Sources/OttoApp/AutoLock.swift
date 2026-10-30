import AppKit
import CoreGraphics

/// Optional (Settings → Vault): lock otto when the Mac sleeps or its screen locks, or after a while with
/// nobody at the Mac and no agent using otto. Off unless the user picks one.
@MainActor
enum AutoLock {
    private static var timer: Timer?

    static func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { onSleep() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onSleep() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { check() } }
    }

    private static func onSleep() {
        if Prefs.autoLock == "sleep" { Task { await Engine.shared.lock() } }
    }

    private static func check() {
        guard let minutes = Double(Prefs.autoLock), Engine.shared.state == .ready else { return }
        let limit = minutes * 60
        // any key, click or mouse move anywhere on the Mac counts as someone being there
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let lastAgent = Engine.shared.activity.map(\.ts).max().map { Date().timeIntervalSince($0) } ?? .infinity
        if away >= limit && lastAgent >= limit { Task { await Engine.shared.lock() } }
    }
}
