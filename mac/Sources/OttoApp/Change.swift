import AppKit
import SwiftUI

/// An agent wants to change a stored secret: save_secret over a value that's saved, or a new 2FA QR code
/// for an entry that has one.
@MainActor
struct ChangeRequest {
    var entry: String
    var entryID: String?
    var agent: String
    var action: String
    /// what macOS shows under Touch ID
    var reason: String
    var field: String
    /// the new value; nil when it wouldn't mean anything to read (a 2FA secret), and `label` says what it is
    var value: String?
    var label: String?
    /// hidden until the user asks to see it (everything but a username)
    var secret: Bool
    var sites: [String]
    var kind: Kind
    var folder: String?
    var verified: Bool
    /// the user set a PIN for remote: a Mac without Touch ID asks for that
    var pin: Bool
    /// set when the user can answer from their phone too
    var ask: String?
    /// seconds that request has left
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        let ch = a["change"] as? [String: Any] ?? [:]
        entry = a["entry"] as? String ?? "?"
        entryID = a["entry_id"] as? String
        agent = a["agent"] as? String ?? "an agent"
        action = a["action"] as? String ?? "change it"
        reason = a["prompt"] as? String ?? Auth.reason(agent: agent, action: action, entry: entry)
        field = ch["field"] as? String ?? "value"
        value = ch["value"] as? String
        label = ch["label"] as? String
        secret = ch["secret"] as? Bool ?? true
        sites = a["sites"] as? [String] ?? []
        kind = Kind(a["entry_kind"] as? String)
        folder = a["folder"] as? String
        verified = a["verified"] as? Bool ?? true
        pin = a["pin"] as? Bool ?? false
        ask = a["ask"] as? String
        expiresIn = a["expires_in"] as? Double
    }

    /// "change remote-test’s password"
    var what: String {
        let r = Auth.reason(agent: agent, action: action, entry: entry)
        let lead = "let \(agent) "
        return r.hasPrefix(lead) ? String(r.dropFirst(lead.count)) : r
    }
}

/// What the change would write, then Touch ID. A Mac without Touch ID asks for the otto PIN instead, when
/// the user set one (otherwise macOS asks for the Mac password).
struct ChangeRequestView: View {
    let r: ChangeRequest
    /// the reply for the service: approved, or declined (Not now)
    let finish: ([String: Any]) -> Void

    @State private var shown = false
    @State private var usePIN: Bool
    @State private var pin = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var pinFocus: Bool

    init(r: ChangeRequest, finish: @escaping ([String: Any]) -> Void) {
        self.r = r
        self.finish = finish
        _usePIN = State(initialValue: r.pin && !Auth.hasTouchID)
    }

    private var entry: Entry? { Engine.shared.entries.first { $0.id == r.entryID } }
    private var site: String? { r.sites.first }
    private var subtitle: String {
        var parts = [r.sites.isEmpty ? r.kind.title.lowercased() : r.sites.joined(separator: ", ")]
        if let f = r.folder, !f.isEmpty { parts.append("asked in \(f)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("New \(r.field)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                    Card { valueRow }
                }
                if usePIN {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Your otto PIN (no Touch ID on this Mac)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        PINInput(placeholder: "6 digits", text: $pin).focused($pinFocus)
                    }
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text("what's saved now gets replaced.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Not now") { finish(["approved": false, "declined": true]) }
                    .buttonStyle(SoftButton())
                    .keyboardShortcut(.cancelAction)
                Button { Task { await confirm() } } label: {
                    Label(busy ? "Waiting…" : r.action.hasPrefix("replace") ? "Replace" : "Change", systemImage: usePIN ? "lock.fill" : Auth.hasTouchID ? "touchid" : "lock.fill")
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (usePIN && pin.count != 6))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .focusEffectDisabled()
        .background(alignment: .top) { RequestWash(tint: EntryIcon.tint(kind: r.kind, card: entry?.card, site: site, app: nil)).padding(.top, -32).ignoresSafeArea() }
        .onAppear { if usePIN { DispatchQueue.main.async { pinFocus = true } } }
        .onChange(of: pin) { _, v in
            let digits = String(v.filter(\.isNumber).prefix(6))
            if digits != v { pin = digits }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                EntryIcon(kind: r.kind, card: entry?.card, site: site, app: nil, name: r.entry, size: 58)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .entryHint(r.entryID)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Text(r.agent).foregroundStyle(AgentStyle.color(r.agent))) wants to \(r.what)")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if !r.verified {
                Label("otto couldn’t check who this is by its signature. only allow it if you started it yourself.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let value = r.value {
                Group {
                    if shown || !r.secret {
                        Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(8)
                    } else {
                        // the same dots whatever its length
                        Text(String(repeating: "•", count: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if r.secret {
                    Button { shown.toggle() } label: {
                        Image(systemName: shown ? "eye.slash" : "eye").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(shown ? "hide it" : "show it")
                }
            } else {
                Text(r.label ?? "a new value").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func confirm() async {
        busy = true
        problem = nil
        defer { busy = false }
        if usePIN {
            do {
                let res = try await Engine.shared.call("check_pin", ["pin": pin]) as? [String: Any]
                if res?["ok"] as? Bool == true { return finish(["approved": true]) }
                let left = res?["left"] as? Int ?? 0
                pin = ""
                problem = "that's not the PIN. \(left) \(left == 1 ? "try" : "tries") left."
                pinFocus = true
            } catch {
                // too many wrong PINs: the Mac password still works
                pin = ""
                usePIN = false
                problem = "\((error as? OttoError)?.message ?? error.localizedDescription). click \(r.action.hasPrefix("replace") ? "Replace" : "Change") to use the Mac password."
            }
            return
        }
        let ok: Bool
        if let ask = r.ask {
            ok = await Auth.approve(reason: r.reason, ask: ask) == .yes
        } else {
            ok = await Auth.approve(reason: r.reason)
        }
        if ok { return finish(["approved": true]) }
        problem = Auth.hasTouchID ? "Touch ID didn't go through. try again, or Not now." : "the password didn't go through. try again, or Not now."
    }
}
