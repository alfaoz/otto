import AppKit
import Foundation
import Observation

struct OttoError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    var errorDescription: String? { message }
}

struct TotpInfo: Hashable {
    var issuer: String?
    var account: String?
    var period: Int
}

/// The user's sealed yes to bypass for an entry (the service only reports one that's valid).
struct Bypass: Hashable {
    var at: Date
    /// nil: until the user turns it off
    var until: Date?
    /// "touch_id" or "password"
    var auth: String
    var statement: String
    var askedBy: String?
    var reason: String?

    init?(_ j: [String: Any]?) {
        guard let j, let at = (j["at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        self.at = at
        until = (j["until"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        auth = j["auth"] as? String ?? "touch_id"
        statement = j["statement"] as? String ?? ""
        askedBy = j["asked_by"] as? String
        reason = j["reason"] as? String
    }

    var authLabel: String { auth == "touch_id" ? "Touch ID" : "Mac password" }
}

struct Entry: Identifiable, Hashable {
    let id: String
    var name: String
    /// login, card, key, note, value or mac (see Kind)
    var kind: String
    var card: CardInfo?
    var username: String?
    var sites: [String]
    var apps: [String]
    /// optional limits: only agents working in these folders, only these agents (empty: no limit)
    var folders: [String]
    var agents: [String]
    var policy: String
    var scripts: Bool
    /// no notification when agents use it without asking
    var quiet: Bool
    var hasPassword: Bool
    var totp: TotpInfo?
    var fields: [String]
    /// an imported 2FA code not attached to a login (agents can't use it)
    var library: Bool
    /// "app", "delivered" (SMS/email), "none", or nil when unknown
    var twoFactor: String?
    var modified: Date?
    var bypass: Bypass?
    /// a value kept out of sight, and then only for these exact commands
    var secret: Bool
    var commands: [String]
    /// a value that isn't secret, as it is
    var value: String?

    init?(_ j: [String: Any]) {
        guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
        self.id = id
        self.name = name
        kind = j["kind"] as? String ?? "login"
        card = CardInfo(j["card"] as? [String: Any])
        username = j["username"] as? String
        sites = j["sites"] as? [String] ?? []
        apps = j["apps"] as? [String] ?? []
        folders = j["folders"] as? [String] ?? []
        agents = j["agents"] as? [String] ?? []
        policy = j["policy"] as? String ?? "ask"
        scripts = j["scripts"] as? Bool ?? false
        quiet = j["quiet"] as? Bool ?? false
        hasPassword = j["has_password"] as? Bool ?? false
        fields = j["fields"] as? [String] ?? []
        library = j["library"] as? Bool ?? false
        twoFactor = j["two_factor"] as? String
        modified = (j["modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        bypass = Bypass(j["bypass"] as? [String: Any])
        secret = j["secret"] as? Bool ?? false
        commands = j["commands"] as? [String] ?? []
        value = j["value"] as? String
        if let t = j["totp"] as? [String: Any] {
            totp = TotpInfo(issuer: t["issuer"] as? String, account: t["account"] as? String, period: t["period"] as? Int ?? 30)
        }
    }

    /// bypass, unless its end date has passed since the list was loaded
    var activeBypass: Bypass? {
        guard let b = bypass, b.until.map({ $0 > Date() }) ?? true else { return nil }
        return b
    }

    /// what agents get: "bypass" or the entry's policy
    var access: String { activeBypass != nil ? "bypass" : policy }

    var subtitle: String {
        [username, sites.first ?? apps.first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct Code: Hashable {
    var code: String
    var period: Int
}

struct Activity: Identifiable, Hashable {
    let id = UUID()
    var ts: Date
    var agent: String
    var op: String
    var entry: String?
    var ok: Bool
    var detail: String
    /// on a bypass_on line: whether its consent carries the vault's seal (nil: not a bypass line)
    var sealed: Bool?
    /// the app that started the agent ("T3 Code")
    var via: String?
    /// the agent's working folder
    var folder: String?
    /// not an agent otto could verify by its signature: Auto and bypass didn't apply
    var unverified: Bool
    /// the agent got a link and waits for the user (at the Mac or from their phone): not a failure
    var pending: Bool
    /// a command line in full (`detail` has a short one) and the reason the agent gave for it
    var command: String?
    var why: String?

    init?(_ j: [String: Any]) {
        guard let op = j["op"] as? String else { return nil }
        sealed = j["sealed"] as? Bool
        ts = (j["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        agent = j["agent"] as? String ?? "?"
        self.op = op
        entry = j["entry"] as? String
        ok = j["ok"] as? Bool ?? false
        detail = j["detail"] as? String ?? ""
        via = j["via"] as? String
        folder = j["folder"] as? String
        unverified = j["unverified"] as? Bool ?? false
        pending = j["pending"] as? Bool ?? false
        command = j["command"] as? String
        why = j["why"] as? String
    }

    /// the command this line is about: in full on newer lines, else what `detail` has between backticks
    var fullCommand: String? {
        if let command { return command }
        guard op == "sudo" || op == "approve_command",
              let open = detail.firstIndex(of: "`"), let close = detail.lastIndex(of: "`"), open < close else { return nil }
        let c = detail[detail.index(after: open)..<close]
        return c.isEmpty ? nil : String(c)
    }

    /// `detail` for beside the command's own box: "ran the command as root"
    var detailBesideCommand: String {
        guard fullCommand != nil, let open = detail.firstIndex(of: "`"), let close = detail.lastIndex(of: "`"), open < close else { return detail }
        return detail.replacingCharacters(in: open...close, with: "the command")
    }

    /// went wrong, as opposed to still waiting for the user
    var failed: Bool { !ok && !pending }
}

/// An entry in the trash and when it went there.
struct Trashed: Identifiable, Hashable {
    var entry: Entry
    var deleted: Date?
    var id: String { entry.id }

    init?(_ j: [String: Any]) {
        guard let e = Entry(j) else { return nil }
        entry = e
        deleted = (j["deleted"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// when the service empties it from the trash
    var goes: Date? { deleted.map { $0.addingTimeInterval(30 * 86400) } }
}

/// A copy of the vault the service keeps in backups/.
struct Backup: Identifiable, Hashable {
    let name: String
    let at: Date
    let size: Int
    var id: String { name }

    init?(_ j: [String: Any]) {
        guard let n = j["name"] as? String else { return nil }
        name = n
        at = (j["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        size = j["size"] as? Int ?? 0
    }
}

enum EngineState: Equatable {
    case starting
    case ready
    /// the user's auto-lock closed the vault; Touch ID opens it again
    case locked
    case needsKey(String)
    case failed(String)
}

/// Runs the otto service (the Rust binary inside the bundle) and speaks its private protocol:
/// JSON lines over the child's stdin/stdout. Only this app can unlock, edit, or approve.
@MainActor @Observable
final class Engine {
    static let shared = Engine()

    var state: EngineState = .starting
    var entries: [Entry] = []
    var codes: [String: Code] = [:]
    var activity: [Activity] = []
    /// deleted entries, newest first: they stay a month (the service empties older ones)
    var trash: [Trashed] = []
    var browsers: [String] = []
    /// remote approvals from the phone (nil until the service says)
    var remote: RemoteStatus?
    var firstRun = false
    /// agent events since Activity was last looked at
    var unseen = 0
    /// what an agent is doing right now, by lowercased entry name (cleared after a few seconds)
    var live: [String: Activity] = [:]
    var panelVisible = false {
        didSet { if panelVisible { refreshCodes() } }
    }

    @ObservationIgnored var onActivity: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var ticker: Timer?

    /// dev: OTTO_HOME points the app (and its service) at a throwaway vault, see tests/demo.py
    nonisolated static let devHome = ProcessInfo.processInfo.environment["OTTO_HOME"]

    static var supportDir: URL {
        if let devHome { return URL(filePath: devHome) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/otto")
    }

    static var vaultURL: URL { supportDir.appending(path: "vault.kdbx") }

    static var binaryURL: URL? {
        if let p = ProcessInfo.processInfo.environment["OTTO_BIN"] { return URL(filePath: p) }
        return Bundle.main.url(forAuxiliaryExecutable: "otto")
    }

    // MARK: lifecycle

    func start() {
        guard process == nil else { return }
        guard let bin = Self.binaryURL else {
            state = .failed("the otto binary is missing from the app bundle")
            return
        }
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = bin
        p.arguments = ["daemon"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let log = Self.supportDir.appending(path: "service.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            p.standardError = h
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(d) } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(code: proc.terminationStatus) } }
        }
        do {
            try p.run()
        } catch {
            state = .failed("couldn't start the otto service: \(error.localizedDescription)")
            return
        }
        process = p
        input = inPipe.fileHandleForWriting
        Task { await unlock() }
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { Engine.shared.tick() }
            }
        }
    }

    /// Auto-lock (or Lock otto): the service forgets the open vault and every earlier yes. Agents get "locked".
    func lock() async {
        guard state == .ready else { return }
        _ = try? await call("lock")
        state = .locked
        entries = []
        codes = [:]
        trash = []
    }

    /// Touch ID, then the vault opens with the key from the keychain as at launch.
    @discardableResult
    func unlock(reason: String) async -> Bool {
        guard state == .locked else { return state == .ready }
        guard await Auth.approve(reason: reason), let key = Keychain.read() else { return false }
        await open(with: key, create: false)
        return state == .ready
    }

    /// After the service kept stopping: a fresh set of tries.
    func retry() {
        restarts = 0
        state = .starting
        start()
    }

    private func exited(code: Int32) {
        process = nil
        input = nil
        for (_, c) in pending { c.resume(throwing: OttoError("gone", "the otto service stopped")) }
        pending.removeAll()
        restarts += 1
        if restarts > 5 {
            state = .failed("the otto service keeps stopping (exit \(code)). see ~/Library/Application Support/otto/service.log")
            return
        }
        state = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
    }

    private func unlock() async {
        let exists = FileManager.default.fileExists(atPath: Self.vaultURL.path)
        var key = Keychain.read()
        if key == nil {
            if exists {
                state = .needsKey("the vault exists but its key isn't in your keychain. enter your recovery key.")
                return
            }
            key = Keychain.newKey()
            do { try Keychain.write(key!) } catch {
                state = .failed("couldn't save the vault key to your keychain: \(error.localizedDescription)")
                return
            }
        }
        await open(with: key!, create: !exists)
    }

    /// Unlock with a typed recovery key; on success it goes into the keychain.
    func unlock(recoveryKey: String) async {
        // accept it typed with spaces, without dashes, or in lowercase
        let raw = recoveryKey.uppercased().filter { $0.isLetter || $0.isNumber }
        let key = raw.count == 25
            ? stride(from: 0, to: 25, by: 5).map { i in String(raw.dropFirst(i).prefix(5)) }.joined(separator: "-")
            : recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await open(with: key, create: false)
        if state == .ready { try? Keychain.write(key) }
    }

    private func open(with key: String, create: Bool) async {
        do {
            let r = try await call("unlock", ["password": key, "create": create]) as? [String: Any]
            if r?["created"] as? Bool == true { firstRun = true }
            restarts = 0
            state = .ready
            await refresh()
            await loadActivity()
            await loadRemote()
            if firstRun || ProcessInfo.processInfo.environment["OTTO_SHOW_ONBOARDING"] != nil {
                Windows.shared.showOnboarding()
            } else if Self.devHome == nil {
                Notices.shared.askIfNeverAsked()
            }
        } catch let e as OttoError where e.code == "unlock_failed" {
            state = .needsKey("that key doesn't open the vault.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: protocol

    @discardableResult
    func call(_ op: String, _ args: [String: Any] = [:]) async throws -> Any {
        guard let input else { throw OttoError("gone", "the otto service isn't running") }
        let id = nextID
        nextID += 1
        let msg: [String: Any] = ["type": "req", "id": id, "op": op, "args": args]
        let data = try JSONSerialization.data(withJSONObject: msg) + Data([0x0A])
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            input.write(data)
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        input.write(data + Data([0x0A]))
    }

    private func ingest(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "res":
            guard let id = m["id"] as? Int, let c = pending.removeValue(forKey: id) else { return }
            if m["ok"] as? Bool == true {
                c.resume(returning: m["result"] ?? NSNull())
            } else {
                let e = m["error"] as? [String: Any]
                c.resume(throwing: OttoError(e?["code"] as? String ?? "error", e?["message"] as? String ?? "unknown error"))
            }
        case "req":
            let id = m["id"] as? Int ?? 0
            let op = m["op"] as? String ?? ""
            let args = m["args"] as? [String: Any] ?? [:]
            Task {
                do {
                    let r = try await self.serve(op, args)
                    self.send(["type": "res", "id": id, "ok": true, "result": r])
                } catch {
                    let e = error as? OttoError ?? OttoError("error", error.localizedDescription)
                    self.send(["type": "res", "id": id, "ok": false, "error": ["code": e.code, "message": e.message]])
                }
            }
        case "event":
            let data = m["data"] as? [String: Any] ?? [:]
            switch m["event"] as? String {
            case "changed":
                Task { await refresh() }
            case "activity":
                if let a = Activity(data) {
                    unseen += 1
                    activity.insert(a, at: 0)
                    if let key = a.entry?.lowercased() {
                        live[key] = a
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            if self.live[key]?.id == a.id { self.live[key] = nil }
                        }
                    }
                    if activity.count > 300 { activity.removeLast(activity.count - 300) }
                    onActivity?(a.ok)
                }
            case "browser":
                browsers = data["browsers"] as? [String] ?? []
            case "used":
                Notices.shared.used(data)
            case "ask_done":
                // answered from the phone (or it ran out): the window or prompt for it goes away
                guard let ask = data["ask"] as? String else { break }
                Windows.shared.askDone(ask)
                Auth.cancel(ask: ask)
                Notices.shared.askDone(ask)
            case "ask":
                Notices.shared.ask(data)
            case "remote":
                remote = RemoteStatus(data["status"] as? [String: Any] ?? data)
            case "remote_notice":
                Notices.shared.remote(data)
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: requests from the service

    private func serve(_ op: String, _ a: [String: Any]) async throws -> Any {
        switch op {
        case "approve":
            // a change to a stored secret: a window showing what it would become, then Touch ID
            if a["change"] is [String: Any] { return await Windows.shared.approveChange(ChangeRequest(a)) }
            let agent = a["agent"] as? String ?? "an agent"
            let entry = a["entry"] as? String ?? "?"
            let action = a["action"] as? String ?? "use it"
            // cards and sudo come with their own wording (which card where, which command)
            let reason = a["prompt"] as? String ?? Auth.reason(agent: agent, action: action, entry: entry)
            // the phone can answer it too: only a real no ends it there
            if let ask = a["ask"] as? String { return await Auth.approve(reason: reason, ask: ask).reply }
            let ok = await Auth.approve(reason: reason)
            return ["approved": ok]
        case "unlock":
            // an agent needs otto while it's auto-locked: macOS shows "otto is trying to <reason>"
            let agent = a["agent"] as? String ?? "an agent"
            return ["unlocked": await unlock(reason: "unlock itself, because \(agent) wants to use it")]
        case "approve_command":
            return await Windows.shared.approveCommand(CommandRequest(a))
        case "save_dialog":
            return try await Windows.shared.saveRequest(SaveRequest(a))
        case "approve_site":
            return await Windows.shared.approveSite(SiteRequest(a))
        case "consent_bypass":
            return await Windows.shared.consentBypass(BypassRequest(a))
        case "approve_browser":
            return await Windows.shared.approveBrowser(BrowserRequest(a))
        case "mac_password":
            return await Windows.shared.macPassword(MacPasswordRequest(a))
        case "type_text":
            let name = try Typer.type(a["text"] as? String ?? "", allowedApps: a["apps"] as? [String] ?? [], anyApp: a["any"] as? Bool ?? false)
            return ["app": name]
        case "decode_qr":
            guard let b64 = a["png"] as? String, let png = Data(base64Encoded: b64) else {
                throw OttoError("bad_request", "no image")
            }
            return ["payloads": QR.decode(png: png)]
        case "scan_screen":
            return ["payloads": try await QR.scanScreen()]
        default:
            throw OttoError("bad_request", "the app doesn't know `\(op)`")
        }
    }

    // MARK: data

    func refresh() async {
        guard let list = try? await call("entries") as? [[String: Any]] else { return }
        entries = list.compactMap(Entry.init)
        refreshCodes()
        if let t = try? await call("trash") as? [[String: Any]] { trash = t.compactMap(Trashed.init) }
    }

    func loadActivity() async {
        guard let list = try? await call("log", ["limit": 200]) as? [[String: Any]] else { return }
        activity = list.compactMap(Activity.init)
    }

    private func tick() {
        guard state == .ready, panelVisible || Windows.shared.hasOpenWindows else { return }
        let now = Int(Date().timeIntervalSince1970)
        // codes only change at period boundaries; ask again then (or if any are missing)
        if codes.count != entries.filter({ $0.totp != nil }).count || entries.contains(where: { e in
            guard let t = e.totp else { return false }
            return now % t.period == 0
        }) {
            refreshCodes()
        }
    }

    func refreshCodes() {
        guard state == .ready else { return }
        Task {
            guard let r = try? await call("codes") as? [String: [String: Any]] else { return }
            var out: [String: Code] = [:]
            for (id, v) in r {
                if let c = v["code"] as? String { out[id] = Code(code: c, period: v["period"] as? Int ?? 30) }
            }
            codes = out
        }
    }

    func secret(_ id: String, _ field: String) async -> String? {
        try? await call("secret", ["id": id, "field": field]) as? String
    }

    func upsert(_ patch: [String: Any]) async throws -> Entry? {
        let r = try await call("upsert", ["patch": patch]) as? [String: Any]
        return r.flatMap(Entry.init)
    }

    /// `consent` is what the consent window returned: the sentence ticked, how the user confirmed, until when.
    func bypassOn(_ id: String, consent: [String: Any]) async throws {
        var args = consent
        args.removeValue(forKey: "granted")
        args["id"] = id
        try await call("bypass_on", args)
    }

    func bypassOff(_ id: String) async throws {
        try await call("bypass_off", ["id": id])
    }

    func delete(_ id: String) async throws {
        try await call("delete", ["id": id])
    }

    func restore(_ id: String) async throws {
        try await call("restore", ["id": id])
    }

    func purge(_ id: String) async throws {
        try await call("purge", ["id": id])
    }

    func emptyTrash() async throws {
        try await call("empty_trash")
    }

    func backups() async -> [Backup] {
        (try? await call("backups") as? [[String: Any]])?.compactMap(Backup.init) ?? []
    }

    func restoreBackup(_ name: String) async throws {
        try await call("restore_backup", ["name": name])
    }

    func parseOTP(_ text: String) async -> Result<[String: Any], OttoError> {
        do {
            return .success(try await call("parse_otp", ["text": text]) as? [String: Any] ?? [:])
        } catch {
            return .failure(error as? OttoError ?? OttoError("error", error.localizedDescription))
        }
    }
}
