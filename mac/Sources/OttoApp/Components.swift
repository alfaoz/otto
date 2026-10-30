import AppKit
import SwiftUI

/// otto's surfaces: quiet fills over the window, color only where it means something
/// (a site's own color, an agent's color, green for done, red for trouble).
enum Palette {
    static let card = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
    static let field = Color.primary.opacity(0.07)
    static let hover = Color.primary.opacity(0.05)
    static let track = Color.primary.opacity(0.07)
    /// the agent's speech bubble in a request window
    static let bubble = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.22) : NSColor(white: 0, alpha: 0.055)
    })
    /// the selected segment of a Pills control: raised white in light mode, a lighter grey in dark mode
    static let knob = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .white
    })
}

/// A rounded group of rows with hairlines between them.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider().opacity(0.6).padding(.leading, 14) }
                    row
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // a highlighted first or last row keeps the corners round
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

/// A titled block of the detail pane: small label above a card.
struct Block<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            Card { content }
        }
    }
}

extension Block where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        self.content = content()
    }
}

/// Plain rounded field, no blue focus ring.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.tertiary))
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? .system(.body, design: .monospaced) : .body)
        .focusEffectDisabled()
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    /// An editable value that sits exactly where its text sits when it isn't being edited:
    /// the fill grows outward, the text doesn't move.
    func inlineField() -> some View {
        textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, -7)
            .padding(.vertical, -4)
    }
}

/// A form-ish line used in windows (request, import): label on the left, control on the right.
struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Countdown ring for a code; computed from the clock, so it moves smoothly without asking the service.
struct Ring: View {
    let period: Int
    var size: CGFloat = 15
    /// the seconds left, inside the ring (for the big one)
    var seconds = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let left = Double(period) - t.truncatingRemainder(dividingBy: Double(period))
            let ending = left <= 5
            ZStack {
                Circle().stroke(Palette.track, lineWidth: size > 24 ? 3 : 2)
                Circle()
                    .trim(from: 0, to: left / Double(period))
                    .stroke(ending ? Color.red : Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: size > 24 ? 3 : 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if seconds {
                    Text("\(Int(left.rounded(.up)))")
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ending ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

struct CodeText: View {
    let code: String
    var size: CGFloat = 17
    var weight: Font.Weight = .medium

    var body: some View {
        Text(grouped)
            .font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
            .tracking(size > 24 ? 1 : 0.3)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: code)
    }

    var grouped: String {
        guard code.count >= 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

/// An agent as a colored dot with its logo (or its initial); a small red mark when what it asked for was refused.
struct AgentAvatar: View {
    let agent: String
    var size: CGFloat = 26
    var failed = false

    var body: some View {
        let browser = AgentStyle.browserIcon(agent)
        Group {
            if let browser {
                Image(nsImage: browser).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if let logo = AgentStyle.logo(agent) {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.56, height: size * 0.56)
            } else {
                Text(String(agent.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            }
        }
            .foregroundStyle(.black.opacity(0.72))
            .frame(width: size, height: size)
            .background(browser == nil ? AgentStyle.color(agent) : .clear, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if failed {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.26, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.46, height: size * 0.46)
                        .background(.red, in: Circle())
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum Policy {
    static let options: [(String, String)] = [("auto", "Auto"), ("ask", "Touch ID"), ("never", "Never")]
    /// bypass is only ever per entry, after the consent window
    static let bypass = ("bypass", "Bypass")
    static let symbols = ["auto": "bolt.fill", "ask": "touchid", "never": "nosign", "bypass": "lock.open.fill"]

    static func symbol(_ p: String) -> String {
        switch p {
        case "auto": "bolt.fill"
        case "never": "nosign"
        case "bypass": "lock.open.fill"
        default: "touchid"
        }
    }

    /// cards ask every time, so they don't offer Auto
    static func options(_ kind: Kind) -> [(String, String)] {
        kind.offersAuto ? options : options.filter { $0.0 != "auto" }
    }

    /// what agents may do with this kind of entry, in a few words
    static func help(_ p: String, kind: Kind) -> String {
        switch (p, kind) {
        case ("bypass", .card): "agents fill it at any checkout without asking, also while you're away"
        case ("bypass", .mac): "agents run any sudo command without asking, also while you're away"
        case ("auto", .mac): "agents run any sudo command as root without asking. you only get a notification afterwards"
        case ("never", .value): "agents can't see it, and it doesn't come back in any command"
        case (_, .value): "agents see its name and can leave a blank for it. it only comes back with your yes"
        case ("never", _): help(p)
        case (_, .card): "agents need your Touch ID for every fill, and you see which site"
        case (_, .mac): "agents need your Touch ID for every sudo command, and you see the command"
        case ("auto", .key): "agents use it without asking, in scripts (otto run)"
        case ("auto", .note): "agents use it without asking"
        default: help(p)
        }
    }

    /// what agents may do, in a few words
    static func help(_ p: String) -> String {
        switch p {
        case "auto": "agents use it without asking, only on its website or app"
        case "never": "agents can't see or use it"
        case "bypass": "agents use it without asking, on any site or app, also while you're away"
        default: "agents need your Touch ID each time (one approval lasts 10 minutes)"
        }
    }
}

/// Only shown where it changes something: Touch ID, Never and Bypass. Auto is the normal case.
struct PolicyGlyph: View {
    let policy: String

    var body: some View {
        if policy != "auto" {
            Image(systemName: Policy.symbol(policy))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(policy == "never" ? AnyShapeStyle(.red.opacity(0.8)) : policy == "bypass" ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .help(Policy.help(policy))
        }
    }
}

extension Activity {
    var symbol: String {
        if pending { return "hourglass" }
        if !ok { return "xmark.circle" }
        switch op {
        case "code": return "number"
        case "fill": return "rectangle.and.pencil.and.ellipsis"
        case "fill_code": return "number.square"
        case "fill_on_site": return "globe"
        case "fill_card": return "creditcard"
        case "sudo": return "lock.laptopcomputer"
        case "type": return "keyboard"
        case "request_save": return "tray.and.arrow.down"
        case "enroll": return "qrcode"
        case "save": return "square.and.arrow.down"
        case "env": return "terminal"
        case "approve_command": return "terminal.fill"
        case "browser_on": return "globe"
        case "bypass_on", "request_bypass": return "lock.open.fill"
        case "bypass_off", "end_bypass": return "lock.fill"
        case "saved": return "tray.and.arrow.down"
        case "approved": return "checkmark.circle"
        case "declined": return "hand.raised"
        case "remote_on", "remote_off", "remote_pair", "remote_forget", "remote_pin", "remote_locked": return "iphone"
        default: return "circle"
        }
    }

    var verb: String {
        if pending { return waitingVerb }
        switch op {
        case "code": return ok ? "got a 2FA code" : "wanted a 2FA code"
        case "fill": return ok ? "filled the login" : "tried to fill the login"
        case "fill_code": return ok ? "filled a 2FA code" : "tried to fill a 2FA code"
        case "fill_on_site": return ok ? "used it on a new site" : "wanted it on a new site"
        case "fill_card": return ok ? "filled a card" : "tried to fill a card"
        case "sudo": return ok ? "ran a sudo command" : "wanted to run a sudo command"
        case "type": return ok ? "typed a secret" : "tried to type a secret"
        case "request_save": return ok ? "got a login saved" : "asked you to save a login"
        case "enroll": return ok ? "set up 2FA" : "tried to set up 2FA"
        case "save": return ok ? "saved a secret" : "tried to save a secret"
        case "env": return ok ? "used it in a script" : "wanted it for a script"
        case "approve_command": return ok ? "ran a command you allowed" : "asked to run a command"
        case "browser_on": return "allowed a browser"
        case "bypass_on": return "turned on bypass"
        case "bypass_off", "end_bypass": return "turned off bypass"
        case "request_bypass": return ok ? "got bypass turned on" : "asked you for bypass"
        case "bridge": return ok ? "connected" : "couldn’t connect"
        case "notify_off": return "turned off notifications"
        case "notify_on": return "turned on notifications"
        case "cut_off": return "stopped a session"
        case "saved": return "saved a login"
        case "remembered": return "had otto remember"
        case "forgot_remembered": return "had otto forget"
        case "approved": return "allowed it"
        case "declined": return "said no"
        case "remote_on": return "turned on remote"
        case "remote_off": return "turned off remote"
        case "remote_pair": return "paired a device"
        case "remote_forget": return "removed a device"
        case "remote_pin": return "wrong PIN"
        case "remote_locked": return "remote turned off"
        default: return op
        }
    }

    /// an agent that sent the user a link (or is waiting at the Mac) for their answer
    private var waitingVerb: String {
        switch op {
        case "code": return "asked for a 2FA code"
        case "fill": return "asked to fill the login"
        case "fill_code": return "asked to fill a 2FA code"
        case "fill_on_site": return "asked to use it on a site"
        case "fill_card": return "asked to fill a card"
        case "type": return "asked to type a secret"
        case "request_save": return "asked you to save a login"
        case "enroll": return "asked to set up 2FA"
        case "save": return "asked to save a secret"
        case "env": return "asked to use it in a script"
        case "approve_command": return "asked to run a command"
        default: return "is waiting for you"
        }
    }
}

/// How long a window has before it closes by itself. Orange for the last minute.
struct ClosesIn: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let left = max(0, Int(deadline.timeIntervalSince(t.date).rounded(.up)))
            Label("closes in \(left / 60):\(String(format: "%02d", left % 60))", systemImage: "timer")
                .font(.caption.monospacedDigit())
                .foregroundStyle(left <= 60 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

/// Quiet secondary button: a soft capsule that brightens on hover.
struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.11 : 0.075), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }
    }
}

/// The one main action of a window: ink on cream in dark mode, cream on ink in light mode.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(configuration.isPressed ? 0.7 : 0.9), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.35)
        }
    }
}

/// A small symbol button that lights up under the pointer.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .background(hover ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Copies whatever `value` returns (nil: nothing to copy, e.g. Touch ID was cancelled),
/// then says "copied" in green for a moment.
struct CopyButton: View {
    var help = "copy"
    let value: () async -> String?
    var concealed = false
    var clearAfter: TimeInterval?
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            Task {
                guard let v = await value() else { return }
                Setup.copy(v, concealed: concealed, clearAfter: clearAfter)
                copied = true
                try? await Task.sleep(for: .seconds(1.3))
                copied = false
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
                .opacity(copied ? 0 : 1)
                .frame(width: 26, height: 24)
                .background(hover && !copied ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .trailing) {
                    if copied { Text("copied").font(.callout).foregroundStyle(.green).fixedSize() }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Segmented choice in otto's colors (no system accent).
struct Pills<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var small = false
    var symbols: [T: String] = [:]
    /// a symbol that means something (bypass: orange)
    var tints: [T: Color] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = selection == value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = symbols[value] {
                            Image(systemName: s)
                                .font(.system(size: small ? 9.5 : 10.5, weight: .semibold))
                                .foregroundStyle(tints[value].map { AnyShapeStyle($0) } ?? AnyShapeStyle(on ? .primary : .secondary))
                        }
                        Text(title).lineLimit(1)
                    }
                    .font(.system(size: small ? 11 : 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .primary : .secondary)
                    .frame(maxWidth: small ? nil : .infinity)
                    .padding(.horizontal, small ? 9 : 8)
                    .padding(.vertical, small ? 3 : 5)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.knob)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct Placeholder: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(SoftButton()).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
