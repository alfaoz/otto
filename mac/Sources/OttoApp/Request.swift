import AppKit
import SwiftUI

/// What an agent asked for with request_save.
struct SaveRequest {
    var name: String
    var site: String?
    var app: String?
    var username: String?
    var needs: [String]
    var note: String?
    var agent: String
    var existing: Entry?
    /// set when the user can answer from their phone too
    var ask: String?
    /// seconds that request has left
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        name = a["name"] as? String ?? ""
        site = a["site"] as? String
        app = a["app"] as? String
        username = a["username"] as? String
        needs = (a["needs"] as? [String] ?? []).map { $0 == "2fa" ? "totp" : $0 }
        note = a["note"] as? String
        agent = a["agent"] as? String ?? "an agent"
        existing = (a["existing"] as? [String: Any]).flatMap(Entry.init)
        ask = a["ask"] as? String
        expiresIn = a["expires_in"] as? Double
    }
}

/// An agent asked for a login it doesn't have. Ask only for what it needs, in plain words.
struct SaveRequestView: View {
    let r: SaveRequest
    let finish: ([String: Any]?) -> Void
    var closeGuard: CloseGuard?

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var twoFactor = "app"
    @State private var otp = ""
    @State private var fromID: String?
    @FocusState private var focus: Bool

    private var needsPassword: Bool { r.needs.isEmpty || r.needs.contains("password") }
    private var needsTOTP: Bool { r.needs.contains("totp") }
    private var key: String { r.site ?? r.app ?? r.name }
    private var tint: Color { Icons.shared.tint(key) }
    private var agentColor: Color { AgentStyle.color(r.agent) }
    private var appName: String? {
        guard let id = r.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return r.app }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 13) {
                if needsPassword {
                    Row(label: "Username") { Field(placeholder: "email or username", text: $username) }
                    Row(label: "Password") {
                        HStack(spacing: 6) {
                            Field(placeholder: r.existing?.hasPassword == true ? "unchanged" : "password", text: $password, secure: !showPassword, mono: showPassword)
                                .focused($focus)
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
                if needsTOTP {
                    Row(label: "2FA") {
                        TwoFAPicker(hints: [r.site, r.name, r.username].compactMap { $0 }, agent: r.agent, kind: $twoFactor, otp: $otp, fromID: $fromID)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider().opacity(0.5)
            HStack(alignment: .center, spacing: 10) {
                Label {
                    Text("\(r.agent) never sees these\(r.site.map { " and can only use them on \($0)" } ?? "").")
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not now") { finish(nil) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(alignment: .top) { wash.padding(.top, -32).ignoresSafeArea() }
        .onAppear {
            username = r.username ?? r.existing?.username ?? ""
            closeGuard?.isDirty = { !password.isEmpty || !otp.trimmingCharacters(in: .whitespaces).isEmpty || fromID != nil }
            closeGuard?.save = { if ready { save() } }
            DispatchQueue.main.async { focus = needsPassword }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                SiteIcon(site: r.site, name: r.name, size: 58)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Text(r.agent).foregroundStyle(agentColor)) needs your \(r.name) login")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.site ?? r.app.map { "the \(appName ?? $0) app" } ?? "new entry")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if needsPassword { chip("password", "key.fill") }
                if needsTOTP { chip("2FA code", "number") }
            }
            if let note = r.note, !note.isEmpty { AgentNote(agent: r.agent, text: note) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wash: some View { RequestWash(tint: tint) }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    private var ready: Bool {
        let gotPassword = !password.isEmpty || r.existing?.hasPassword == true
        let got2FA = twoFactor != "app" || fromID != nil || !otp.trimmingCharacters(in: .whitespaces).isEmpty || r.existing?.totp != nil
        return (!needsPassword || gotPassword) && (!needsTOTP || got2FA)
    }

    private func save() {
        var p: [String: Any] = [:]
        if let e = r.existing {
            p["id"] = e.id
        } else {
            p["name"] = r.name
            p["policy"] = "auto"
            p["sites"] = r.site.map { [$0] } ?? []
            p["apps"] = r.app.map { [$0] } ?? []
        }
        if needsPassword { p["username"] = username }
        if !password.isEmpty { p["password"] = password }
        if needsTOTP {
            if twoFactor == "app" {
                let o = otp.trimmingCharacters(in: .whitespacesAndNewlines)
                if !o.isEmpty { p["otp"] = o } else if let id = fromID { p["otp_from"] = id }
                p["two_factor"] = ""
            } else {
                p["two_factor"] = twoFactor
            }
        }
        finish(p)
    }
}

/// What the agent says about its request, as a speech bubble next to its avatar.
struct AgentNote: View {
    let agent: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: agent, size: 24)
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Palette.bubble, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14))
        }
    }
}

/// The site's color at the top of a request window, fading out under the form with no visible edge.
struct RequestWash: View {
    let tint: Color

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.30), location: 0),
                .init(color: tint.opacity(0.16), location: 0.45),
                .init(color: tint.opacity(0.05), location: 0.75),
                .init(color: tint.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 440)
        .allowsHitTesting(false)
    }
}
