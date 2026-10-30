import AppKit
import SwiftUI

/// Something the agent left out of a command for the user to fill in: `--password {{app password}}`.
struct CommandBlank: Identifiable {
    var name: String
    var secret: Bool
    /// otto remembers something for it; `value` is what, unless it's a secret (those never leave the service)
    var saved = false
    var value: String?
    /// a secret with this name is saved, for these other commands: the user can choose to use it here too
    var elsewhere: [String]?
    var id: String { name }
    var mark: String { "{{\(name)}}" }
}

/// An agent wants the user's yes for one exact command (`otto approve`, the run_command tool): one it
/// shouldn't run on its own say-so. Every command asks; a yes covers that one run. With blanks, the user
/// fills them in too, and the service runs the command itself so the agent doesn't see what they typed.
@MainActor
struct CommandRequest {
    var agent: String
    var command: String
    var folder: String?
    /// the agent's own words for what it does and why
    var why: String?
    var verified: Bool
    /// the user set a PIN for remote: a Mac without Touch ID asks for that
    var pin: Bool
    /// set when the user can answer from their phone too
    var ask: String?
    /// seconds that request has left
    var expiresIn: Double?
    var blanks: [CommandBlank]

    init(_ a: [String: Any]) {
        blanks = (a["blanks"] as? [[String: Any]] ?? []).compactMap { b in
            (b["name"] as? String).map { CommandBlank(name: $0, secret: b["secret"] as? Bool ?? false, saved: b["saved"] as? Bool ?? false, value: b["value"] as? String, elsewhere: b["elsewhere"] as? [String]) }
        }
        agent = a["agent"] as? String ?? "an agent"
        command = a["command"] as? String ?? "?"
        folder = a["folder"] as? String
        why = a["why"] as? String
        verified = a["verified"] as? Bool ?? true
        pin = a["pin"] as? Bool ?? false
        ask = a["ask"] as? String
        expiresIn = a["expires_in"] as? Double
    }

    /// macOS shows: "otto is trying to let claude run `rm -rf build`."
    var reason: String {
        let one = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let short = one.count > 80 ? String(one.prefix(79)) + "…" : one
        return "let \(agent) run `\(short)`"
    }
}

/// The command as it will run, where, and the agent's reason; then Touch ID (or the PIN on a Mac without it).
struct CommandRequestView: View {
    let r: CommandRequest
    let finish: ([String: Any]) -> Void

    @State private var usePIN: Bool
    @State private var pin = ""
    @State private var busy = false
    @State private var problem: String?
    /// what the user typed, by blank
    @State private var values: [String: String] = [:]
    @State private var shownSecrets: Set<String> = []
    /// the blanks marked to keep
    @State private var remember: Set<String>
    /// the blanks that use a secret saved for another command
    @State private var reuse: Set<String> = []
    @FocusState private var pinFocus: Bool
    @FocusState private var blankFocus: String?

    init(r: CommandRequest, finish: @escaping ([String: Any]) -> Void) {
        self.r = r
        self.finish = finish
        _usePIN = State(initialValue: r.pin && !Auth.hasTouchID)
        _remember = State(initialValue: Set(r.blanks.filter(\.saved).map(\.name)))
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: r.blanks.compactMap { b in b.value.map { (b.name, $0) } }))
    }

    private var allFilled: Bool {
        r.blanks.allSatisfy { $0.saved || reuse.contains($0.name) || !(values[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The command as it stands: what's filled in shows (a secret as dots), what isn't stands out.
    private var preview: AttributedString {
        var out = AttributedString()
        var rest = Substring(r.command)
        while let (at, blank) = r.blanks.compactMap({ b in rest.range(of: b.mark).map { ($0, b) } }).min(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            out += AttributedString(String(rest[..<at.lowerBound]))
            let typed = values[blank.name] ?? ""
            var piece: AttributedString
            if typed.isEmpty && (blank.saved || reuse.contains(blank.name)) {
                piece = AttributedString(String(repeating: "•", count: 12))
                piece.foregroundColor = .primary
            } else if typed.isEmpty {
                piece = AttributedString(blank.name)
                piece.foregroundColor = .orange
            } else {
                piece = AttributedString(blank.secret && !shownSecrets.contains(blank.name) ? String(repeating: "•", count: min(typed.count, 12)) : typed)
                piece.foregroundColor = .primary
            }
            out += piece
            rest = rest[at.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    private func blankField(_ b: CommandBlank) -> some View {
        let text = Binding(get: { values[b.name] ?? "" }, set: { values[b.name] = $0 })
        let keep = Binding(get: { remember.contains(b.name) }, set: { if $0 { remember.insert(b.name) } else { remember.remove(b.name) } })
        let using = reuse.contains(b.name)
        let use = Binding(get: { using }, set: {
            if $0 {
                reuse.insert(b.name)
                values[b.name] = ""
            } else {
                reuse.remove(b.name)
            }
        })
        let hint = (b.saved && b.secret) || using ? Text("saved").foregroundStyle(.tertiary) : nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(b.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                Spacer()
                Toggle("Remember", isOn: keep).toggleStyle(.checkbox).controlSize(.small).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Group {
                    if b.secret && !shownSecrets.contains(b.name) {
                        SecureField("", text: text, prompt: hint)
                    } else {
                        TextField("", text: text, prompt: hint)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focusEffectDisabled()
                .focused($blankFocus, equals: b.name)
                .disabled(using)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if b.secret {
                    let showing = shownSecrets.contains(b.name)
                    IconButton(symbol: showing ? "eye.slash" : "eye", help: showing ? "hide it" : "show it") {
                        if showing { shownSecrets.remove(b.name) } else { shownSecrets.insert(b.name) }
                    }
                }
            }
            if let others = b.elsewhere {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Use the “\(b.name)” you saved", isOn: use).toggleStyle(.checkbox).controlSize(.small)
                    Text(others.first.map { "it's saved for `\($0)`\(others.count > 1 ? " and \(others.count - 1) more" : ""). otto won't use it here unless you tick this." } ?? "you haven't used it in a command yet. otto won't use it here unless you tick this.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Command").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                    Card {
                        ScrollView {
                            Text(preview)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                        }
                        .frame(maxHeight: 180)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let why = r.why {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Why, in \(r.agent)’s words").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
                    }
                }
                ForEach(r.blanks) { blankField($0) }
                if !r.blanks.isEmpty {
                    Text("what you remember stays in your vault. a secret only comes back for this exact command.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, 4)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text(r.blanks.isEmpty ? "it runs once, as you. otto doesn't check what it does." : "it runs once, as you. \(r.agent) gets its output, with what you typed hidden.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Don’t Allow") { finish(["approved": false, "declined": true]) }
                    .buttonStyle(SoftButton())
                    .keyboardShortcut(.cancelAction)
                Button { Task { await confirm() } } label: {
                    Label(busy ? "Waiting…" : "Allow", systemImage: usePIN ? "lock.fill" : Auth.hasTouchID ? "touchid" : "lock.fill")
                }
                .buttonStyle(PrimaryButton())
                .disabled(busy || (usePIN && pin.count != 6) || !allFilled)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .focusEffectDisabled()
        .background(alignment: .top) { RequestWash(tint: AgentStyle.color(r.agent)).padding(.top, -32).ignoresSafeArea() }
        .onAppear {
            DispatchQueue.main.async {
                if let first = r.blanks.first { blankFocus = first.name } else if usePIN { pinFocus = true }
            }
        }
        .onChange(of: pin) { _, v in
            let digits = String(v.filter(\.isNumber).prefix(6))
            if digits != v { pin = digits }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.13)], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Text(r.agent).foregroundStyle(AgentStyle.color(r.agent))) \(r.blanks.isEmpty ? "wants to run a command" : "needs you to finish a command")")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.folder.map { "in \($0)" } ?? "you decide whether it runs")
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

    /// The yes, with what the user typed: it goes to the service, never to the agent.
    private var allowed: [String: Any] {
        r.blanks.isEmpty ? ["approved": true] : [
            "approved": true,
            "values": r.blanks.map { values[$0.name] ?? "" },
            "remember": r.blanks.map { remember.contains($0.name) },
            "reuse": r.blanks.map { reuse.contains($0.name) },
        ]
    }

    private func confirm() async {
        busy = true
        problem = nil
        defer { busy = false }
        if usePIN {
            do {
                let res = try await Engine.shared.call("check_pin", ["pin": pin]) as? [String: Any]
                if res?["ok"] as? Bool == true { return finish(allowed) }
                let left = res?["left"] as? Int ?? 0
                pin = ""
                problem = "that's not the PIN. \(left) \(left == 1 ? "try" : "tries") left."
                pinFocus = true
            } catch {
                pin = ""
                usePIN = false
                problem = "\((error as? OttoError)?.message ?? error.localizedDescription). click Allow to use the Mac password."
            }
            return
        }
        let ok: Bool
        if let ask = r.ask {
            ok = await Auth.approve(reason: r.reason, ask: ask) == .yes
        } else {
            ok = await Auth.approve(reason: r.reason)
        }
        if ok { return finish(allowed) }
        problem = Auth.hasTouchID ? "Touch ID didn't go through. try again, or Don’t Allow." : "the password didn't go through. try again, or Don’t Allow."
    }
}
