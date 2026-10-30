import Foundation
import LocalAuthentication

/// Touch ID (or the Mac password) for "ask" entries and anything that changes a secret.
@MainActor
enum Auth {
    private static var queue: Task<Void, Never>?
    /// requests (by ask id) waiting for their prompt or showing it, and the prompt's context once it's up
    private static var waiting = Set<String>()
    private static var onScreen: [String: LAContext] = [:]
    /// answered elsewhere (the phone) or ran out before their turn came
    private static var done = Set<String>()

    /// How a prompt the phone can answer too ended. Only a real no ends the request: anything else
    /// (the screen locked, the prompt taken away, no Touch ID) leaves the phone's link working.
    enum Answer {
        case yes, declined, unanswered

        var reply: [String: Any] {
            switch self {
            case .yes: ["approved": true]
            case .declined: ["approved": false, "declined": true]
            case .unanswered: ["approved": false]
            }
        }
    }

    /// Touch ID can be used right now (not on a Mac without it, or with the lid closed). In a dev build,
    /// OTTO_NO_TOUCH_ID=1 acts as a Mac without it.
    static var hasTouchID: Bool {
        if Engine.devHome != nil, ProcessInfo.processInfo.environment["OTTO_NO_TOUCH_ID"] == "1" { return false }
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// macOS shows: "otto is trying to <reason>."
    static func reason(agent: String, action: String, entry: String) -> String {
        if action.contains("its ") {
            return "let \(agent) \(action.replacingOccurrences(of: "its ", with: "\(entry)’s "))"
        }
        return "let \(agent) \(action) for \(entry)"
    }

    /// One prompt at a time; concurrent requests wait their turn.
    static func approve(reason: String) async -> Bool {
        await inTurn { await evaluate(reason) }
    }

    /// A request the phone can answer too (`ask` is its id): its prompt goes away when the phone answers.
    static func approve(reason: String, ask: String) async -> Answer {
        waiting.insert(ask)
        return await inTurn {
            defer {
                waiting.remove(ask)
                done.remove(ask)
            }
            if done.contains(ask) { return .unanswered }
            return await answer(reason, ask: ask)
        }
    }

    /// The request was answered from the phone or ran out: skip its prompt, or take it off the screen.
    static func cancel(ask: String) {
        guard waiting.contains(ask) else { return }
        done.insert(ask)
        onScreen[ask]?.invalidate()
    }

    private static func inTurn<T>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { () -> T in
            _ = await previous?.value
            return await body()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    /// A yes only the person at this Mac can give: Touch ID, with no password fallback, when the Mac has it
    /// (a computer-use agent could type a password). Macs without Touch ID use the password.
    /// Returns how they confirmed ("touch_id" or "password"), or nil.
    static func confirm(_ reason: String) async -> String? {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            ctx.localizedFallbackTitle = ""
            let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
            return ok ? "touch_id" : nil
        }
        return await evaluate(reason) ? "password" : nil
    }

    static func evaluate(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    /// Cancel and too many wrong fingers are the person saying no; everything else is nobody answering.
    private static func answer(_ reason: String, ask: String) async -> Answer {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return .unanswered }
        onScreen[ask] = ctx
        defer { onScreen[ask] = nil }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .yes : .unanswered
        } catch let e as LAError where e.code == .userCancel || e.code == .authenticationFailed {
            return .declined
        } catch {
            return .unanswered
        }
    }
}
