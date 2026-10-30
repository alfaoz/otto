import AppKit
import SwiftUI

/// Turning on bypass for one entry: asked for by an agent (request_bypass, from the chat) or by the
/// user from the entry's Access row.
struct BypassRequest {
    var entry: String
    var entryID: String?
    var sites: [String]
    var apps: [String]
    /// nil when the user started it in otto
    var agent: String?
    var reason: String?
    /// how long the agent suggested (what the user said in the chat)
    var hours: Int?

    /// seconds until the service stops waiting for this window
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        expiresIn = a["expires_in"] as? Double
        entry = a["entry"] as? String ?? "?"
        entryID = a["entry_id"] as? String
        sites = a["sites"] as? [String] ?? []
        apps = a["apps"] as? [String] ?? []
        agent = a["agent"] as? String
        reason = a["reason"] as? String
        hours = a["hours"] as? Int
    }

    init(entry e: Entry) {
        entry = e.name
        entryID = e.id
        sites = e.sites
        apps = e.apps
    }
}

/// Bypass takes a yes the agent can't fake: the user reads what changes, ticks the sentence, and
/// confirms with Touch ID here. The service then seals that yes to this one entry with the vault key.
struct BypassConsentView: View {
    let r: BypassRequest
    /// nil: not now. otherwise what the service seals: the sentence ticked, how they confirmed, until when
    let finish: ([String: Any]?) -> Void

    @State private var understood = false
    @State private var duration: Int
    @State private var busy = false
    @State private var problem: String?

    /// seconds; 0 = until the user turns it off
    private let durations: [(Int, String)]

    init(r: BypassRequest, finish: @escaping ([String: Any]?) -> Void) {
        self.r = r
        self.finish = finish
        var d: [(Int, String)] = [(86_400, "1 day"), (7 * 86_400, "1 week"), (0, "Until I turn it off")]
        var pick = 0
        if let h = r.hours, h > 0 {
            pick = h * 3600
            if !d.contains(where: { $0.0 == pick }) {
                d.insert((pick, h < 48 ? "\(h) hours" : "\(Int((Double(h) / 24).rounded())) days"), at: d.firstIndex { $0.0 == 0 || $0.0 > pick } ?? 0)
            }
        }
        durations = d
        _duration = State(initialValue: pick)
    }

    private var site: String? { r.sites.first }
    /// the entry, from the vault (for its kind and card)
    private var entry: Entry? { Engine.shared.entries.first { $0.id == r.entryID } }
    private var kind: Kind { entry?.kindValue ?? .login }
    /// "login", "card"... as the sentence names it
    private var noun: String {
        switch kind {
        case .login: "login"
        case .card: "card"
        case .key: "key"
        case .note: "note"
        case .value: "value"
        case .mac: "Mac password"
        }
    }
    private var statement: String {
        switch kind {
        case .card: "i understand an agent can pay with my \(r.entry) card anywhere without asking me, and an agent that's been tricked could pay the wrong site."
        case .mac: "i understand an agent can run any command as root on this Mac without asking me, and an agent that's been tricked could do real damage."
        default: "i understand an agent can use my \(r.entry) \(noun) anywhere without asking me, and an agent that's been tricked could hand it to the wrong site."
        }
    }

    /// what agents could do without asking, for this kind of entry
    private var risks: [Line] {
        let away = Line("hand.raised.slash", "use it with no Touch ID and no windows, also while you're away")
        switch kind {
        case .card: return [away, Line("cart", "fill it into any checkout they say is the right one,", hint: ("even a fake one", Self.fakeSiteNote))]
        case .value: return [away]
        case .mac: return [away, Line("terminal", "run any command as root with it, through sudo")]
        case .key, .note: return [away, Line("keyboard", "type it into whichever app is in front"), Line("terminal", "hand it to scripts, if you allow scripts")]
        case .login: return [
            away,
            Line("globe", "fill it on any site they say is its login page,", hint: ("even a fake one", Self.fakeSiteNote)),
            Line("keyboard", "type it into whichever app is in front"),
        ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                group("Without asking you, agents could", risks, risk: true)
                group("Still true", [
                    Line("eye.slash", kind == .card ? "they never see the card's number or CVC" : kind == .login ? "they never see the password or the 2FA secret" : "they never see it"),
                    Line("touchid", "changing what's saved still needs your Touch ID"),
                    Line("waveform.path.ecg", "every use shows in Activity, marked bypass"),
                ], risk: false)
                HStack(spacing: 12) {
                    Text("For").foregroundStyle(.secondary)
                    Pills(options: durations, selection: $duration, small: true).fixedSize()
                }
                Toggle(isOn: $understood) {
                    Text(statement).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text("agents can turn it off, never on.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { finish(nil) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button { Task { await confirm() } } label: {
                    Label(busy ? "Waiting…" : "Turn On", systemImage: "touchid")
                }
                .buttonStyle(PrimaryButton())
                .disabled(!understood || busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 540)
        .focusEffectDisabled()
        .background(alignment: .top) { RequestWash(tint: EntryIcon.tint(kind: kind, card: entry?.card, site: site, app: r.apps.first)).padding(.top, -32).ignoresSafeArea() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                EntryIcon(kind: kind, card: entry?.card, site: site, app: r.apps.first, name: r.entry, size: 58)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .entryHint(r.entryID)
                VStack(alignment: .leading, spacing: 5) {
                    Group {
                        let name = Text(r.entry).underline(pattern: .dot)
                        if let agent = r.agent {
                            Text("\(Text(agent).foregroundStyle(AgentStyle.color(agent))) wants bypass for your \(name) \(noun)")
                        } else {
                            Text("Turn on bypass for \(name)?")
                        }
                    }
                    .font(.system(size: 21, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .entryHint(r.entryID)
                    Text("agents use this one \(noun) without asking you")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let agent = r.agent, let reason = r.reason, !reason.isEmpty { AgentNote(agent: agent, text: reason) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// what the agent does about fake sites (the skill tells it to), and why that's no promise
    static let fakeSiteNote = "agents are told to check it's really the service's login page first (its own domain, no lookalike spelling, not reached through a link someone sent) and to weigh every sign of a fake. that's their judgment, not a guarantee: a convincing lookalike, or a page made to trick them, can still get it."

    private struct Line: Identifiable {
        let symbol: String
        let text: String
        /// a phrase at the end with more to say on hover
        var hint: (phrase: String, note: String)?
        var id: String { text }

        init(_ symbol: String, _ text: String, hint: (String, String)? = nil) {
            self.symbol = symbol
            self.text = text
            self.hint = hint.map { (phrase: $0.0, note: $0.1) }
        }
    }

    private func group(_ title: String, _ lines: [Line], risk: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            Card {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: line.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(risk ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .frame(width: 18)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(line.text).fixedSize(horizontal: false, vertical: true)
                            if let hint = line.hint { HoverHint(phrase: hint.phrase, note: hint.note) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private func confirm() async {
        busy = true
        problem = nil
        defer { busy = false }
        guard let how = await Auth.confirm("turn on bypass for \(r.entry)") else {
            problem = "Touch ID didn't go through, so bypass stays off."
            return
        }
        var out: [String: Any] = ["granted": true, "statement": statement, "auth": how]
        if duration > 0 {
            out["until"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(duration)))
        }
        finish(out)
    }
}

/// A phrase with a dotted underline that says more on hover (solid underline while the pointer is on it).
struct HoverHint: View {
    let phrase: String
    let note: String
    @State private var hover = false

    var body: some View {
        Text(phrase)
            .underline(true, pattern: hover ? .solid : .dot)
            .fixedSize()
            .onHover { hover = $0 }
            .help(note)
    }
}

extension View {
    /// Hover: which login this is (its username, sites or apps, and notes), from the vault itself,
    /// not from what the agent says.
    func entryHint(_ id: String?) -> some View { modifier(EntryHint(id: id)) }
}

private struct EntryHint: ViewModifier {
    let id: String?
    @State private var notes: String?

    func body(content: Content) -> some View {
        content
            .help(text)
            .task(id: id) {
                // a secure note's text is the secret itself
                if let id, Engine.shared.entries.first(where: { $0.id == id })?.kindValue != .note { notes = await Engine.shared.secret(id, "notes") }
            }
    }

    private var text: String {
        guard let id, let e = Engine.shared.entries.first(where: { $0.id == id }) else { return "" }
        var lines: [String] = []
        switch e.kindValue {
        case .card: lines.append("card: \(e.card?.label ?? "card")\(e.card?.expiry.map { ", expires \($0)" } ?? "")")
        case .login: lines.append("user: \((e.username ?? "").ifEmpty("none saved"))")
        default: lines.append(e.kindValue.title.lowercased())
        }
        if !e.sites.isEmpty { lines.append("site: \(e.sites.joined(separator: ", "))") }
        if !e.apps.isEmpty { lines.append("app: \(e.apps.joined(separator: ", "))") }
        if let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            lines.append("notes: \(n.count > 400 ? String(n.prefix(400)) + "…" : n)")
        }
        return lines.joined(separator: "\n")
    }
}
