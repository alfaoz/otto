import SwiftUI

/// A website as otto keeps it: the host alone ("amazon.com.tr" from "https://www.amazon.com.tr/cart").
/// The service checks again and turns international names into xn-- form.
enum Domain {
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }
        if s == "localhost" || isIPv4(s) { return s }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        let label = { (l: Substring) in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-") && l.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        guard labels.count >= 2, labels.allSatisfy(label), let tld = labels.last,
              tld.hasPrefix("xn--") || (tld.count >= 2 && tld.allSatisfy(\.isLetter)) else { return nil }
        return s
    }

    private static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { UInt8($0) != nil }
    }

    /// endings to offer for a bare name ("amazon"): .com, and this country's own
    static let endings: [String] = {
        var e = ["com"]
        guard let r = Locale.current.region?.identifier.lowercased(), r.count == 2, r != "us" else { return e }
        let local = ["tr": "com.tr", "gb": "co.uk", "jp": "co.jp", "au": "com.au", "br": "com.br", "in": "co.in", "nz": "co.nz", "za": "co.za", "kr": "co.kr"]
        if let l = local[r] { e.append(l) }
        e.append(r)
        return e
    }()
}

/// Lays its children out in lines, wrapping when a line is full.
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// Websites as chips with their icons. Type or paste (a URL, an email address, a list), and a comma,
/// space or leaving the field adds them; only real domains get in. A bare name offers its endings,
/// and sites from your other logins come up as you type.
struct SiteField: View {
    @Binding var sites: [String]
    @Binding var draft: String
    let placeholder: String
    /// sites saved on other entries
    var known: [String] = []

    @FocusState private var focused: Bool
    @State private var problem: String?

    private var suggestions: [String] {
        let t = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        if let d = Domain.normalize(t) { out.append(d) }
        out += known.filter { k in k.hasPrefix(t) || k.split(separator: ".").contains { $0.hasPrefix(t) } }
        if !t.contains("."), t.count >= 2, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            out += Domain.endings.map { "\(t).\($0)" }
        }
        var seen = Set(sites)
        return out.filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sites.isEmpty {
                Flow(spacing: 6, lineSpacing: 6) {
                    ForEach(sites, id: \.self) { chip($0) }
                }
                .animation(.snappy(duration: 0.22), value: sites)
            }
            TextField("", text: $draft, prompt: Text(sites.isEmpty ? placeholder : "add another").foregroundStyle(.tertiary))
                .focused($focused)
                .onSubmit { commit() }
                .inlineField()
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { add(s) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                Text(s)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("add \(s)")
                    }
                }
                .transition(.opacity)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: suggestions)
        .animation(.easeOut(duration: 0.15), value: problem)
        .onChange(of: draft) { _, new in
            problem = nil
            if new.contains(where: { ", \n\t;".contains($0) }) { commit() }
        }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func chip(_ s: String) -> some View {
        HStack(spacing: 6) {
            SiteIcon(site: s, name: s, size: 16)
            Text(s).lineLimit(1)
            Button {
                sites.removeAll { $0 == s }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("remove \(s)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Palette.field, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func add(_ s: String) {
        if !sites.contains(s) { sites.append(s) }
        draft = ""
        problem = nil
    }

    /// what's typed becomes chips; anything that isn't a website stays in the field, with a word why
    private func commit() {
        let parts = draft.split(whereSeparator: { ", \n\t;".contains($0) }).map(String.init)
        var bad: [String] = []
        for p in parts {
            if let d = Domain.normalize(p) {
                if !sites.contains(d) { sites.append(d) }
            } else {
                bad.append(p)
            }
        }
        draft = bad.joined(separator: " ")
        problem = bad.first.map { b in
            !b.contains(".") && b.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
                ? "add its ending, like \(b.lowercased()).\(Domain.endings.first ?? "com")"
                : "“\(b)” isn't a website"
        }
    }
}

/// What an API key looks like it's for, from how it starts. Only a guess, used to fill in an empty
/// name, website and variable; the key itself never leaves the Mac.
struct KeyHint: Equatable {
    let provider: String
    let what: String
    let site: String
    let env: String
    var live = false
    /// publishable keys are meant to be public
    var notSecret = false

    var name: String { "\(provider) \(what)" }

    static func of(_ key: String) -> KeyHint? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 8 else { return nil }
        return table.first { k.hasPrefix($0.0) }?.1
    }

    /// the hint for a key saved on a provider's site (console.anthropic.com: Anthropic)
    static func of(site: String?) -> KeyHint? {
        guard let site, !site.isEmpty else { return nil }
        return table.first { site == $0.1.site || site.hasSuffix(".\($0.1.site)") || $0.1.site.hasSuffix(".\(site)") }?.1
    }

    private static let table: [(String, KeyHint)] = [
        ("sk_live_", KeyHint(provider: "Stripe", what: "live secret key", site: "stripe.com", env: "STRIPE_SECRET_KEY", live: true)),
        ("rk_live_", KeyHint(provider: "Stripe", what: "live restricted key", site: "stripe.com", env: "STRIPE_SECRET_KEY", live: true)),
        ("sk_test_", KeyHint(provider: "Stripe", what: "test secret key", site: "stripe.com", env: "STRIPE_SECRET_KEY")),
        ("rk_test_", KeyHint(provider: "Stripe", what: "test restricted key", site: "stripe.com", env: "STRIPE_SECRET_KEY")),
        ("pk_live_", KeyHint(provider: "Stripe", what: "publishable key", site: "stripe.com", env: "STRIPE_PUBLISHABLE_KEY", notSecret: true)),
        ("pk_test_", KeyHint(provider: "Stripe", what: "test publishable key", site: "stripe.com", env: "STRIPE_PUBLISHABLE_KEY", notSecret: true)),
        ("whsec_", KeyHint(provider: "Stripe", what: "webhook secret", site: "stripe.com", env: "STRIPE_WEBHOOK_SECRET")),
        ("sk-ant-", KeyHint(provider: "Anthropic", what: "API key", site: "anthropic.com", env: "ANTHROPIC_API_KEY")),
        ("sk-or-", KeyHint(provider: "OpenRouter", what: "API key", site: "openrouter.ai", env: "OPENROUTER_API_KEY")),
        ("sk-", KeyHint(provider: "OpenAI", what: "API key", site: "openai.com", env: "OPENAI_API_KEY")),
        ("github_pat_", KeyHint(provider: "GitHub", what: "token", site: "github.com", env: "GITHUB_TOKEN")),
        ("ghp_", KeyHint(provider: "GitHub", what: "token", site: "github.com", env: "GITHUB_TOKEN")),
        ("gho_", KeyHint(provider: "GitHub", what: "OAuth token", site: "github.com", env: "GITHUB_TOKEN")),
        ("glpat-", KeyHint(provider: "GitLab", what: "token", site: "gitlab.com", env: "GITLAB_TOKEN")),
        ("xoxb-", KeyHint(provider: "Slack", what: "bot token", site: "slack.com", env: "SLACK_BOT_TOKEN")),
        ("xoxp-", KeyHint(provider: "Slack", what: "user token", site: "slack.com", env: "SLACK_TOKEN")),
        ("AKIA", KeyHint(provider: "AWS", what: "access key ID", site: "aws.amazon.com", env: "AWS_ACCESS_KEY_ID")),
        ("AIza", KeyHint(provider: "Google", what: "API key", site: "console.cloud.google.com", env: "GOOGLE_API_KEY")),
        ("hf_", KeyHint(provider: "Hugging Face", what: "token", site: "huggingface.co", env: "HF_TOKEN")),
        ("npm_", KeyHint(provider: "npm", what: "token", site: "npmjs.com", env: "NPM_TOKEN")),
        ("SG.", KeyHint(provider: "SendGrid", what: "API key", site: "sendgrid.com", env: "SENDGRID_API_KEY")),
        ("re_", KeyHint(provider: "Resend", what: "API key", site: "resend.com", env: "RESEND_API_KEY")),
        ("shpat_", KeyHint(provider: "Shopify", what: "admin token", site: "shopify.com", env: "SHOPIFY_ACCESS_TOKEN")),
        ("dop_v1_", KeyHint(provider: "DigitalOcean", what: "token", site: "digitalocean.com", env: "DIGITALOCEAN_TOKEN")),
        ("gsk_", KeyHint(provider: "Groq", what: "API key", site: "groq.com", env: "GROQ_API_KEY")),
        ("xai-", KeyHint(provider: "xAI", what: "API key", site: "x.ai", env: "XAI_API_KEY")),
        ("pplx-", KeyHint(provider: "Perplexity", what: "API key", site: "perplexity.ai", env: "PERPLEXITY_API_KEY")),
        ("lin_api_", KeyHint(provider: "Linear", what: "API key", site: "linear.app", env: "LINEAR_API_KEY")),
        ("ntn_", KeyHint(provider: "Notion", what: "token", site: "notion.so", env: "NOTION_TOKEN")),
        ("sntrys_", KeyHint(provider: "Sentry", what: "token", site: "sentry.io", env: "SENTRY_AUTH_TOKEN")),
    ]

    /// A key as pasted from an .env line or a doc: `export OPENAI_API_KEY="sk-…"` gives the key and the variable.
    static func clean(_ s: String) -> (key: String, env: String?) {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("export ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        var env: String?
        if let eq = t.firstIndex(of: "="), t[..<eq].count >= 2, t[..<eq].first?.isLetter == true,
           t[..<eq].allSatisfy({ ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" }),
           t.index(after: eq) < t.endIndex, t[t.index(after: eq)] != "=" {
            env = String(t[..<eq])
            t = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { t = String(t.dropFirst().dropLast()) }
        return (t, env)
    }

    /// an environment variable's name: capitals, digits and _
    static func envName(_ s: String) -> String {
        var out = String(s.uppercased().map { $0 == "-" || $0 == " " ? "_" : $0 }.filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }.prefix(64))
        while let f = out.first, f.isNumber { out.removeFirst() }
        return out
    }
}
