import AppKit
import SwiftUI

/// An agent wants to use an entry on a domain that isn't one of its sites (fill_on_site).
struct SiteRequest {
    var entry: String
    var entryID: String?
    /// the page's host, e.g. eu-north-1.signin.aws.amazon.com
    var site: String
    /// what the user types and what gets added, e.g. amazon.com
    var domain: String
    var known: [String]
    var agent: String
    var reason: String
    /// "login" or "2fa_code"
    var what: String

    /// seconds until the service stops waiting for this window
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        expiresIn = a["expires_in"] as? Double
        entry = a["entry"] as? String ?? "?"
        entryID = a["entry_id"] as? String
        site = a["site"] as? String ?? ""
        domain = a["domain"] as? String ?? site
        known = a["known"] as? [String] ?? []
        agent = a["agent"] as? String ?? "an agent"
        reason = a["reason"] as? String ?? ""
        what = a["what"] as? String ?? "login"
    }
}

/// Allowing a new site takes a written yes: the user types the domain, so they've read it.
/// A lookalike domain is the one way an agent could be talked into handing a login to the wrong site.
struct SiteApprovalView: View {
    let r: SiteRequest
    /// nil: don't allow. otherwise whether to add the domain to the entry
    let finish: (Bool?) -> Void

    @State private var typed = ""
    @State private var remember = true
    @FocusState private var focus: Bool

    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == r.domain.lowercased() }
    private var thing: String { r.what == "2fa_code" ? "2FA code" : "login" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    line("Saved for") {
                        Text(r.known.isEmpty ? "no website yet" : r.known.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    line("New site") { hostText }
                }
                Label {
                    Text("only allow it if you know \(Text(r.domain).fontWeight(.semibold)) belongs to \(r.entry). a lookalike site can steal the \(thing).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Type \(Text(r.domain).fontWeight(.semibold)) to allow it")
                        .font(.callout)
                    Field(placeholder: "", text: $typed, mono: true)
                        .focused($focus)
                        .onSubmit { if matches { finish(remember) } }
                    Toggle("Add \(r.domain) to \(r.entry)", isOn: $remember)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text(remember ? "agents can then use it there like on its other sites." : "allowed for the next 10 minutes only.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Don't Allow") { finish(nil) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button("Allow") { finish(remember) }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(alignment: .top) { RequestWash(tint: Icons.shared.tint(r.site)).padding(.top, -32).ignoresSafeArea() }
        .onAppear { DispatchQueue.main.async { focus = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                // the login's own icon, from a site it's saved for: the new domain may have none, or a lookalike's
                SiteIcon(site: r.known.first ?? r.site, name: r.entry, size: 58)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Text(r.agent).foregroundStyle(AgentStyle.color(r.agent))) wants to use your \(Text(r.entry).underline(pattern: .dot)) \(thing) on a new site")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .entryHint(r.entryID)
                    Text(r.domain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if !r.reason.isEmpty { AgentNote(agent: r.agent, text: r.reason) }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// the full host, with the part that names the site in bold
    private var hostText: Text {
        let prefix = r.site.hasSuffix(r.domain) ? String(r.site.dropLast(r.domain.count)) : ""
        let main = prefix.isEmpty ? r.site : r.domain
        return Text("\(Text(prefix).foregroundStyle(.secondary))\(Text(main).fontWeight(.semibold))")
            .font(.system(.body, design: .monospaced))
    }

    private func line<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
