import AppKit
import Security
import SwiftUI

/// The selected entry. Edit turns the same rows into fields, in place; a new one starts here empty.
/// Who may use it (Access, Scripts) can be changed right away, without Edit. Each kind has its own rows:
/// a login's username and password, a card's number and expiry, a key, a note, a value, the Mac password.
struct EntryDetail: View {
    /// nil when creating a new login
    let entry: Entry?

    @State private var ui = UIState.shared
    @State private var engine = Engine.shared

    // viewing
    @State private var shownPassword: String?
    @State private var codeCopied = false

    // editing: a draft of the entry
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    /// the saved password once revealed with Touch ID (saving it unchanged doesn't rewrite it)
    @State private var revealed: String?
    @State private var sites = ""
    @State private var apps = ""
    @State private var policy = "auto"
    @State private var scripts = false
    @State private var twoFactor = "app"
    @State private var otp = ""
    @State private var otpFrom: String?
    @State private var removeOTP = false
    @State private var replacingOTP = false
    @State private var original: Snapshot?
    @State private var error: String?
    @State private var busy = false
    /// a card's, an API key's or a note's values while editing; secret ones start empty ("saved, type to change it")
    @State private var values: [String: String] = [:]
    /// plain values as loaded, and saved secrets revealed with Touch ID: saving them unchanged rewrites nothing
    @State private var loaded: [String: String] = [:]
    /// secret drafts showing as text
    @State private var showing: Set<String> = []
    /// view mode: secrets shown after Touch ID
    @State private var shown: [String: String] = [:]
    /// view mode: a card's plain values (name on card, postal code), an API key's variable
    @State private var plain: [String: String] = [:]
    /// a website being typed that isn't a chip yet
    @State private var siteDraft = ""
    /// what was filled in from an API key's look, so a better guess can still replace it
    @State private var guessed: [String: String] = [:]
    /// view mode: the card turned over
    @State private var flipped = false
    /// a value: kept out of sight, and the commands it then comes back for
    @State private var valueHidden = true
    @State private var commands: [String] = []
    @State private var valueCopied = false
    /// a key's or a value's notes while editing, and as loaded
    @State private var about = ""
    @State private var aboutLoaded = ""
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case name, password, secret(String), plain(String) }

    private struct Snapshot: Equatable {
        var name, username, sites, apps, policy, twoFactor: String
        var scripts, valueHidden: Bool
        var commands: [String]
    }

    private var editing: Bool { entry == nil || ui.editing }
    private var kind: Kind { entry?.kindValue ?? ui.newKind }
    private var snapshot: Snapshot {
        Snapshot(name: name, username: username, sites: sites, apps: apps, policy: policy, twoFactor: twoFactor, scripts: scripts, valueHidden: valueHidden, commands: commands)
    }
    private var dirty: Bool {
        snapshot != original
            || (!password.isEmpty && password != revealed)
            || !otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || otpFrom != nil || removeOTP
            || !changed.isEmpty
            || about != aboutLoaded
            || !siteDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// card, API key and note values to save: typed secrets, and plain values that differ from what was loaded
    private var changed: [String: String] {
        values.filter { k, v in Self.secretFields.contains(k) ? !v.isEmpty && v != loaded[k] : v != (loaded[k] ?? "") }
    }
    private static let secretFields: Set<String> = ["number", "cvc", "key", "notes", "value"]
    /// a new card, API key or Mac password needs its secret
    private var missing: String? {
        guard entry == nil else { return nil }
        switch kind {
        case .card: return (values["number"] ?? "").isEmpty ? "the card number" : nil
        case .key: return (values["key"] ?? "").isEmpty ? "the key" : nil
        case .value: return (values["value"] ?? "").isEmpty ? "the value" : nil
        case .mac: return password.isEmpty ? "the password" : nil
        default: return nil
        }
    }
    /// a card can go without a name: it's then called by its brand and last digits
    private var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.isEmpty, kind == .card, let number = values["number"], number.filter(\.isNumber).count >= 4 else { return n }
        return "\(CardInfo.brand(of: number)) \(number.filter(\.isNumber).suffix(4))"
    }
    private var canSave: Bool { !effectiveName.isEmpty && missing == nil && !busy }

    private var site: String? { editing ? split(sites).first : entry?.sites.first }
    private var app: String? { editing ? split(apps).first : entry?.apps.first }
    /// the card as it is, or as it's being typed
    private var card: CardInfo? {
        guard kind == .card else { return nil }
        if editing, let n = values["number"], !n.isEmpty {
            var c = CardInfo(["brand": CardInfo.brand(of: n), "last4": String(n.filter(\.isNumber).suffix(4))])
            c?.expiry = values["expiry"]
            return c
        }
        return entry?.card
    }
    private var code: Code? {
        guard let entry, entry.totp != nil, !removeOTP else { return nil }
        return engine.codes[entry.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if kind == .card { cardFace }
                if let code { codeCard(code) }
                if kind == .value, !editing { valueCard }
                switch kind {
                case .login: if editing || hasLoginRows { Block(entry?.library == true ? "Account" : "Login") { loginRows } }
                case .card: Block("Card") { cardRows }
                case .key: Block("Key") { keyRows }
                case .note: Block("Note") { noteRows }
                case .value: valueBlocks
                case .mac: Block("Mac password") { macRows }
                }
                if let entry, entry.library, !editing { privateNote(entry) } else { Block("Agents") { agentRows } }
                if editing {
                    editFooter
                } else if let entry {
                    recent(entry)
                    if let m = entry.modified {
                        Text("edited \(m.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.tertiary).padding(.leading, 4)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) { wash }
        .toolbar { toolbar }
        .onAppear {
            policy = entry?.policy ?? kind.policy
            scripts = entry?.scripts ?? (kind == .key)
            if editing { beginEdit() }
        }
        .task(id: entry?.modified) {
            guard let entry else { return }
            for f in Self.plainFields[entry.kindValue] ?? [] { plain[f] = await engine.secret(entry.id, f) }
        }
        .onChange(of: editing) { _, now in if now { beginEdit() } }
        .onChange(of: values) { old, new in tidy(old, new) }
        .onChange(of: entry?.policy) { _, p in if !editing, let p { policy = p } }
        .onChange(of: entry?.scripts) { _, s in if !editing, let s { scripts = s } }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 16) {
            // a card shows itself, big, right below
            if kind != .card {
                EntryIcon(kind: kind, card: card, site: site, app: app, name: (editing ? name : entry?.name ?? "").ifEmpty("?"), size: 64, secret: kind == .value && (editing ? valueHidden : entry?.secret == true))
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if editing {
                        TextField("", text: $name, prompt: Text(kind == .card && !effectiveName.isEmpty ? effectiveName : "Name").foregroundStyle(.tertiary))
                            .focused($focus, equals: .name)
                            .frame(maxWidth: 380)
                            .inlineField()
                    } else {
                        Text(entry?.name ?? "").textSelection(.enabled)
                    }
                }
                .font(.system(size: 26, weight: .bold))
                subtitle
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var subtitle: some View {
        if entry == nil {
            Text(kind.newLine).foregroundStyle(.secondary)
        } else if kind == .card, let c = entry?.card {
            HStack(spacing: 6) {
                Text(c.label).foregroundStyle(.secondary)
                if c.expired { Text("expired").foregroundStyle(.red) }
            }
        } else if kind == .note {
            Text("secure note").foregroundStyle(.secondary)
        } else if kind == .mac {
            Text("this Mac's password, only for sudo").foregroundStyle(.secondary)
        } else if kind == .value {
            Text(entry?.secret == true ? "only for the commands below" : "comes back by name").foregroundStyle(.secondary)
        } else if kind == .key, entry?.sites.isEmpty != false {
            Text("key").foregroundStyle(.secondary)
        } else if let s = entry?.sites.first {
            LinkButton(title: s, url: URL(string: "https://\(s)"))
        } else if let a = entry?.apps.first {
            Text("\(appName(a)) app").foregroundStyle(.secondary)
        } else {
            Text(entry?.library == true ? "imported 2FA code" : "no website or app yet").foregroundStyle(.secondary)
        }
    }

    /// The site's color, washing down from the top and gone before the rows.
    private var wash: some View {
        let tint = EntryIcon.tint(kind: kind, card: card, site: site, app: app)
        return LinearGradient(
            stops: [
                .init(color: tint.opacity(0.28), location: 0),
                .init(color: tint.opacity(0.12), location: 0.45),
                .init(color: tint.opacity(0.03), location: 0.8),
                .init(color: tint.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 380)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func codeCard(_ code: Code) -> some View {
        Button {
            Setup.copy(code.code, clearAfter: 30)
            codeCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { codeCopied = false }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    CodeText(code: code.code, size: 40, weight: .semibold)
                    Text(codeCopied ? "copied" : "click to copy")
                        .font(.callout)
                        .foregroundStyle(codeCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
                Spacer()
                Ring(period: code.period, size: 40, seconds: true)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Icons.shared.tint(site: site, app: app).opacity(0.1)).interactive(), in: .rect(cornerRadius: 18))
        .help("copy the code (cleared from the clipboard after 30 seconds)")
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if editing {
            ToolbarItemGroup(placement: .automatic) {
                Button("Cancel") { _ = ui.leave() }
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: { Text(busy ? "Saving…" : "Save").fontWeight(.semibold) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        } else if let entry {
            ToolbarItem(placement: .automatic) {
                Button("Edit") { ui.startEdit(entry) }
                    .keyboardShortcut("e", modifiers: .command)
                    .help("edit (⌘E)")
            }
        }
    }

    // MARK: rows (the same ones in both modes)

    private var hasLoginRows: Bool {
        guard let e = entry else { return true }
        return !(e.username ?? "").isEmpty || e.hasPassword || !e.sites.isEmpty || !e.apps.isEmpty
    }

    @ViewBuilder private var loginRows: some View {
        if editing || !(entry?.username ?? "").isEmpty {
            row("Username") {
                if editing {
                    TextField("", text: $username, prompt: Text("email or username").foregroundStyle(.tertiary)).inlineField()
                } else {
                    Text(entry?.username ?? "").textSelection(.enabled)
                    Spacer()
                    CopyButton(help: "copy the username") { entry?.username }
                }
            }
        }
        if editing || entry?.hasPassword == true { row("Password") { passwordValue } }
        if editing || entry?.sites.isEmpty == false { row("Website") { websiteValue } }
        if editing || entry?.apps.isEmpty == false { row("Mac app") { appsValue } }
    }

    @ViewBuilder private var passwordValue: some View {
        if editing {
            Group {
                let hint = Text(entry?.hasPassword == true ? "saved, type to change it" : kind == .mac ? "the password you log into this Mac with" : "password").foregroundStyle(.tertiary)
                if showPassword {
                    TextField("", text: $password, prompt: hint).font(.system(.body, design: .monospaced))
                } else {
                    SecureField("", text: $password, prompt: hint)
                }
            }
            .focused($focus, equals: .password)
            .inlineField()
            IconButton(symbol: showPassword ? "eye.slash" : "eye", help: entry?.hasPassword == true && password.isEmpty && !showPassword ? "show the saved password (Touch ID)" : "show") {
                Task { await toggleDraftPassword() }
            }
            if kind == .login {
                IconButton(symbol: "wand.and.sparkles", help: "generate a strong password") {
                    password = Self.generate()
                    showPassword = true
                }
            }
        } else {
            Text(shownPassword ?? "••••••••••••")
                .font(shownPassword == nil ? .body : .system(.body, design: .monospaced))
                .textSelection(.enabled)
                // selectable text can stay blank when its string changes; a fresh one draws
                .id(shownPassword != nil)
            Spacer()
            IconButton(symbol: shownPassword == nil ? "eye" : "eye.slash", help: shownPassword == nil ? "show (Touch ID)" : "hide") {
                Task {
                    if shownPassword != nil { shownPassword = nil; return }
                    guard let entry, await Auth.evaluate("show the password for \(entry.name)") else { return }
                    shownPassword = await engine.secret(entry.id, "password")
                }
            }
            CopyButton(help: "copy the password (Touch ID)", value: {
                if let shownPassword { return shownPassword }
                guard let entry else { return nil }
                return await EntryActions.password(entry)
            }, concealed: true, clearAfter: 45)
        }
    }

    @ViewBuilder private var websiteValue: some View {
        if editing {
            siteField(placeholder: "example.com, or paste the login page's address")
        } else {
            HStack(spacing: 10) {
                ForEach(entry?.sites ?? [], id: \.self) { s in LinkButton(title: s, url: URL(string: "https://\(s)"), primary: true) }
            }
            Spacer()
        }
    }

    @ViewBuilder private var appsValue: some View {
        if editing {
            TextField("", text: $apps, prompt: Text("bundle id, only for desktop logins").foregroundStyle(.tertiary)).inlineField()
            Menu {
                ForEach(runningApps, id: \.id) { a in Button(a.name) { addApp(a.id) } }
            } label: {
                Image(systemName: "plus.app")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("add a running app")
        } else {
            HStack(spacing: 12) {
                ForEach(entry?.apps ?? [], id: \.self) { a in
                    HStack(spacing: 6) {
                        if let i = Icons.shared.app(a) {
                            Image(nsImage: i).resizable().frame(width: 18, height: 18)
                        }
                        Text(appName(a))
                    }
                    .help(a)
                }
            }
            Spacer()
        }
    }

    // MARK: a card, a key, a note, a value, the Mac password

    /// The card itself, live: what's typed shows on it as it's typed, and it turns over for the CVC.
    /// Viewing, a click turns it over.
    private var cardFace: some View {
        let typed = CardInput.digits((editing ? values["number"] : shown["number"]) ?? "")
        let brand = typed.isEmpty ? (entry?.card?.brand ?? "Card") : CardInfo.brand(of: typed)
        let expiry = (editing ? values["expiry"] : entry?.card?.expiry) ?? ""
        let cvc = (editing ? values["cvc"] : shown["cvc"]) ?? ""
        let cvcShown = editing && !showing.contains("cvc") ? String(repeating: "•", count: cvc.count) : cvc
        var expired = false
        if var c = CardInfo(["brand": brand]) {
            c.expiry = expiry
            expired = expiry.count == 5 && c.expired
        }
        return CardFace(
            brand: brand, digits: typed, last4: entry?.card?.last4,
            title: editing ? effectiveName : entry?.name ?? "",
            holder: (editing ? values["cardholder"] : plain["cardholder"]) ?? "",
            expiry: expiry, cvc: cvcShown, expired: expired,
            back: editing ? focus == .secret("cvc") : flipped,
            placeholders: editing
        )
        .onTapGesture { if !editing { flipped.toggle() } }
        .help(editing ? "" : flipped ? "turn it back" : "turn it over")
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var cardRows: some View {
        row("Number") {
            secretValue("number", "the card number", placeholder: "1234 1234 1234 1234", secure: false,
                        masked: "•••• •••• •••• \(entry?.card?.last4 ?? "")", display: CardInfo.grouped)
            if editing { numberStatus }
        }
        row("Expiry") {
            if editing {
                TextField("", text: binding("expiry"), prompt: Text("MM/YY").foregroundStyle(.tertiary))
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .plain("expiry"))
                    .inlineField()
                    .frame(width: 70)
                if let note = CardInput.expiryNote(values["expiry"] ?? "") {
                    Text(note.expired ? "expired" : note.label)
                        .foregroundStyle(note.expired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .padding(.leading, 6)
                        .transition(.opacity)
                }
            } else if let e = entry?.card?.expiry {
                Text(e).font(.system(.body, design: .monospaced))
                if let note = CardInput.expiryNote(e) {
                    Text(note.expired ? "expired" : note.label).foregroundStyle(note.expired ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                }
            } else {
                Text("not saved").foregroundStyle(.secondary)
            }
            Spacer()
        }
        if editing || has("cvc") {
            row("CVC") { secretValue("cvc", "the CVC", placeholder: brandTyped == "American Express" ? "4 digits" : "3 digits", secure: true, masked: "•••", width: 92) }
        }
        if editing || !(plain["cardholder"] ?? "").isEmpty { row("Cardholder") { plainValue("cardholder", placeholder: "name as printed on the card") } }
        if editing || !(plain["postal_code"] ?? "").isEmpty { row("Postal code") { plainValue("postal_code", placeholder: "billing address", width: 130) } }
        row("Only on") {
            if editing {
                siteField(placeholder: "any site, or the shops you allow (amazon.com…)")
            } else if entry?.sites.isEmpty == false {
                websiteValue
            } else {
                Text("any site, after your Touch ID").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var brandTyped: String {
        let typed = CardInput.digits(values["number"] ?? "")
        return typed.isEmpty ? (entry?.card?.brand ?? "Card") : CardInfo.brand(of: typed)
    }

    /// how the number is going: how many digits are left, ✓, or a wrong digit somewhere
    @ViewBuilder private var numberStatus: some View {
        let n = values["number"] ?? ""
        if !n.isEmpty {
            CardBadge(brand: brandTyped, size: 30)
                .transition(.scale.combined(with: .opacity))
                .help(brandTyped == "Card" ? "a card brand otto doesn't know" : brandTyped)
        }
        switch CardInput.status(n) {
        case .empty:
            EmptyView()
        case .short(let left):
            Text("\(left) to go").font(.callout).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
        case .good:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
        case .bad:
            Label("check the digits", systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.red).fixedSize()
                .help("a card number's last digit checks the others; this one doesn't add up")
        }
    }

    @ViewBuilder private var keyRows: some View {
        row("Key") {
            secretValue("key", "the key", placeholder: "paste the key, or a line like OPENAI_API_KEY=sk-…", secure: true, masked: "••••••••••••")
            if editing, let h = KeyHint.of(values["key"] ?? "") { keyBadge(h) }
        }
        if editing || !(plain["env"] ?? "").isEmpty {
            row("Variable") {
                if editing {
                    TextField("", text: binding("env"), prompt: Text("e.g. OPENAI_API_KEY").foregroundStyle(.tertiary))
                        .font(.system(.body, design: .monospaced))
                        .focused($focus, equals: .plain("env"))
                        .inlineField()
                } else {
                    Text(plain["env"] ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                }
            }
        }
        if !editing, let entry, entry.scripts {
            let env = (plain["env"] ?? "").ifEmpty(KeyHint.of(site: entry.sites.first)?.env ?? "KEY")
            let line = "otto run --env \(env)=\(Self.shellWord(entry.name)) -- your-command"
            row("In scripts") {
                Text(line)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                CopyButton(help: "copy the command") { line }
            }
        }
        if editing || entry?.sites.isEmpty == false { row("Website") { websiteValue } }
        aboutRow
    }

    /// What a key or a value is, in the user's words. Not a secret, so it shows without Touch ID.
    @ViewBuilder private var aboutRow: some View {
        if editing {
            row("Notes") {
                TextField("", text: $about, prompt: Text("what it's for, how to get a new one").foregroundStyle(.tertiary), axis: .vertical)
                    .inlineField()
            }
        } else if let n = plain["notes"], !n.isEmpty {
            row("Notes") {
                Text(n).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    // MARK: a value

    /// The value itself, big, like a 2FA code: a click copies it.
    private var valueCard: some View {
        let visible = entry?.secret == true ? shown["value"] : entry?.value
        return Button {
            Task {
                guard let entry else { return }
                let v: String?
                if let visible { v = visible } else { v = await EntryActions.secret(entry, "value", "the value") }
                guard let v else { return }
                Setup.copy(v, concealed: entry.secret, clearAfter: entry.secret ? 45 : nil)
                valueCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { valueCopied = false }
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(visible ?? "••••••••••••")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(visible != nil)
                    Text(valueCopied ? "copied" : entry?.secret == true && visible == nil ? "click to copy (Touch ID)" : "click to copy")
                        .font(.callout)
                        .foregroundStyle(valueCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 8)
                if entry?.secret == true {
                    IconButton(symbol: shown["value"] == nil ? "eye" : "eye.slash", help: shown["value"] == nil ? "show (Touch ID)" : "hide") {
                        Task {
                            if shown["value"] != nil {
                                shown["value"] = nil
                                return
                            }
                            guard let entry, await Auth.evaluate("show the value of \(entry.name)") else { return }
                            shown["value"] = await engine.secret(entry.id, "value")
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Shelf.remembered.tint.opacity(0.1)).interactive(), in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var valueBlocks: some View {
        if editing {
            Block("Value") {
                row("Value") { secretValue("value", "the value", placeholder: "what goes in the blank", secure: valueHidden, masked: "") }
                row("Hidden") {
                    Toggle("", isOn: $valueHidden).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Text(valueHidden ? "a secret: hidden until Touch ID, and only for the commands below" : "not a secret: it shows here, and comes back in any command that asks for it by name")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                aboutRow
            }
        } else if let n = plain["notes"], !n.isEmpty {
            Block("Notes") {
                Text(n)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
        }
        if editing ? valueHidden : entry?.secret == true {
            Block("Comes back for") { commandRows }
        } else if !editing {
            Text("comes back in any command with a blank called “\(entry?.name ?? "")”, for you to check before you allow it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// The exact commands a secret value comes back for: its blank stands out, like in the command's window.
    @ViewBuilder private var commandRows: some View {
        if editing {
            ForEach(commands.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("", text: Binding(get: { i < commands.count ? commands[i] : "" }, set: { if i < commands.count { commands[i] = $0 } }), prompt: Text("the exact command, with {{\(name.ifEmpty("its name"))}} where this goes").foregroundStyle(.tertiary), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .inlineField()
                    IconButton(symbol: "minus.circle", help: "stop it coming back for this command") {
                        if i < commands.count { commands.remove(at: i) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            Button { commands.append("") } label: {
                Label("Add a Command", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        } else if let e = entry, !e.commands.isEmpty {
            ForEach(e.commands, id: \.self) { c in
                Text(Self.painted(c, blank: e.name))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
        } else {
            Text("no command yet. when one asks for it, you can choose to use it there.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    /// A command with its blanks standing out by name: this value's in its color, any others quietly.
    static func painted(_ command: String, blank: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(command)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += AttributedString(String(rest[..<open.lowerBound]))
            let name = String(rest[open.upperBound..<close.lowerBound])
            var piece = AttributedString(name)
            if name.caseInsensitiveCompare(blank) == .orderedSame {
                piece.foregroundColor = Shelf.remembered.tint
                piece.backgroundColor = Shelf.remembered.tint.opacity(0.14)
            } else {
                piece.foregroundColor = .secondary
                piece.backgroundColor = Palette.field
            }
            out += piece
            rest = rest[close.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    private func keyBadge(_ h: KeyHint) -> some View {
        HStack(spacing: 5) {
            SiteIcon(site: h.site, name: h.provider, size: 14)
            Text(h.provider).fontWeight(.medium)
            if h.live {
                Text("LIVE").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(.orange, in: Capsule())
            } else if h.notSecret {
                Text("public").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Palette.field, in: Capsule())
        .fixedSize()
        .help(h.live ? "a live \(h.provider) \(h.what): it acts on real money or data" : h.notSecret ? "\(h.provider) \(h.what)s are meant to be public; it's fine to keep one here anyway" : "\(h.provider) \(h.what)")
        .transition(.opacity)
    }

    /// a word as the shell takes it: quoted if it has spaces or quotes
    static func shellWord(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_.@/".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The website chips while editing, with this entry's draft and the sites saved on other entries.
    private func siteField(placeholder: String) -> some View {
        SiteField(
            sites: Binding(get: { split(sites) }, set: { sites = $0.joined(separator: ", ") }),
            draft: $siteDraft,
            placeholder: placeholder,
            known: Array(Set(engine.entries.filter { $0.id != entry?.id }.flatMap(\.sites))).sorted()
        )
    }

    @ViewBuilder private var noteRows: some View {
        if editing {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry == nil ? "agents can read it only if you let them (Access)" : "saved, type to replace it or show it first")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if entry != nil, (values["notes"] ?? "").isEmpty {
                        IconButton(symbol: "eye", help: "show the saved note (Touch ID)") { Task { await toggleDraft("notes", "the note") } }
                    }
                }
                TextEditor(text: binding("notes"))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(14)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let n = shown["notes"] {
                    Text(n).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("hidden").foregroundStyle(.secondary)
                }
                Spacer()
                secretButtons("notes", "the note")
            }
            .padding(14)
        }
    }

    @ViewBuilder private var macRows: some View {
        row("Password") { passwordValue }
        row("Used by") {
            Text(access == "ask" ? "`otto sudo` only, after you approve each command" : "`otto sudo` only").foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// A card's number or CVC, an API key: hidden until Touch ID, copied after Touch ID. Editing, a saved
    /// one stays empty until a new one is typed (or the saved one is shown, with Touch ID).
    @ViewBuilder private func secretValue(_ f: String, _ what: String, placeholder: String, secure: Bool, masked: String, width: CGFloat? = nil, display: @escaping (String) -> String = { $0 }) -> some View {
        if editing {
            let saved = entry != nil && has(f)
            let hint = Text(saved ? (width == nil ? "saved, type to change it" : "saved") : placeholder).font(saved ? .body : nil).foregroundStyle(.tertiary)
            Group {
                if secure && !showing.contains(f) {
                    SecureField("", text: binding(f), prompt: hint)
                } else {
                    TextField("", text: binding(f), prompt: hint).font(.system(.body, design: .monospaced))
                }
            }
            .focused($focus, equals: .secret(f))
            .inlineField()
            .frame(width: width)
            if secure || (saved && f != "value") {
                IconButton(symbol: showing.contains(f) ? "eye.slash" : "eye", help: saved && (values[f] ?? "").isEmpty && !showing.contains(f) ? "show the saved one (Touch ID)" : "show") {
                    Task { await toggleDraft(f, what) }
                }
            }
            if width != nil { Spacer() }
        } else {
            Text(shown[f].map(display) ?? masked)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .id(shown[f] != nil)
            Spacer()
            secretButtons(f, what)
        }
    }

    /// show (Touch ID) and copy (Touch ID) for a saved secret
    @ViewBuilder private func secretButtons(_ f: String, _ what: String) -> some View {
        IconButton(symbol: shown[f] == nil ? "eye" : "eye.slash", help: shown[f] == nil ? "show (Touch ID)" : "hide") {
            Task {
                if shown[f] != nil {
                    shown[f] = nil
                    return
                }
                guard let entry, await Auth.evaluate("show \(what) for \(entry.name)") else { return }
                shown[f] = await engine.secret(entry.id, f)
            }
        }
        CopyButton(help: "copy \(what) (Touch ID)", value: {
            if let v = shown[f] { return v }
            guard let entry else { return nil }
            return await EntryActions.secret(entry, f, what)
        }, concealed: true, clearAfter: 45)
    }

    @ViewBuilder private func plainValue(_ f: String, placeholder: String, width: CGFloat? = nil) -> some View {
        if editing {
            TextField("", text: binding(f), prompt: Text(placeholder).foregroundStyle(.tertiary))
                .focused($focus, equals: .plain(f))
                .inlineField()
                .frame(width: width)
            if width != nil { Spacer() }
        } else {
            Text(plain[f] ?? "").textSelection(.enabled)
            Spacer()
        }
    }

    private func has(_ f: String) -> Bool {
        f == "notes" ? entry?.kindValue == .note : entry?.fields.contains(f) == true
    }

    private func binding(_ f: String) -> Binding<String> {
        Binding(get: { values[f] ?? "" }, set: { values[f] = $0 })
    }

    /// values that aren't secret, shown without Touch ID
    private static let plainFields: [Kind: [String]] = [.card: ["cardholder", "postal_code"], .key: ["env", "notes"], .value: ["notes"]]

    /// Keeps each value in shape as it's typed or pasted (digits where digits go, the card's grouping,
    /// MM/YY), and lets a pasted API key fill in its name, website and variable.
    private func tidy(_ old: [String: String], _ new: [String: String]) {
        guard editing else { return }
        var v = new
        switch kind {
        case .card:
            let brand = CardInfo.brand(of: v["number"] ?? "")
            if let n = v["number"] { v["number"] = CardInput.number(n) }
            if let e = v["expiry"] { v["expiry"] = CardInput.expiry(e, old: old["expiry"] ?? "") }
            if let c = v["cvc"] { v["cvc"] = CardInput.cvc(c, brand: brand) }
            if let h = v["cardholder"] { v["cardholder"] = CardInput.holder(h) }
            if let p = v["postal_code"] { v["postal_code"] = CardInput.postal(p) }
        case .key:
            if let k = v["key"], k != old["key"], !k.isEmpty {
                let pasted = KeyHint.clean(k)
                v["key"] = pasted.key
                if let env = pasted.env { v["env"] = guess("env", v["env"] ?? "", env) ?? v["env"] }
                if let h = KeyHint.of(pasted.key) {
                    if let n = guess("name", name.trimmingCharacters(in: .whitespaces), h.name) { name = n }
                    if let s = guess("site", split(sites).joined(separator: ", "), h.site) { sites = s }
                    if let e = guess("env", v["env"] ?? "", h.env) { v["env"] = e }
                }
            }
            if let e = v["env"] { v["env"] = KeyHint.envName(e) }
        default:
            break
        }
        if v != new { values = v }
    }

    /// a guess goes in where nothing was typed, or over an earlier guess
    private func guess(_ field: String, _ current: String, _ value: String) -> String? {
        guard current.isEmpty || current == guessed[field], current != value else { return nil }
        guessed[field] = value
        return value
    }

    /// With a saved value and nothing typed, the eye shows the saved one after Touch ID.
    private func toggleDraft(_ f: String, _ what: String) async {
        if showing.contains(f) {
            showing.remove(f)
            return
        }
        if let e = entry, has(f), (values[f] ?? "").isEmpty {
            guard await Auth.evaluate("show \(what) for \(e.name)"), let v = await engine.secret(e.id, f) else { return }
            values[f] = v
            loaded[f] = v
        }
        showing.insert(f)
    }

    /// An imported 2FA code: only you can use it, until it's attached to a website or app.
    private func privateNote(_ entry: Entry) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Palette.field, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Only you can use this code").fontWeight(.medium)
                Text("add its website or app and it becomes a login your agents can use.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Make It a Login") { ui.startEdit(entry) }.buttonStyle(SoftButton())
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
    }

    @ViewBuilder private var agentRows: some View {
        row("Access") {
            VStack(alignment: .leading, spacing: 6) {
                Pills(options: accessOptions, selection: accessBinding, symbols: Policy.symbols, tints: ["bypass": .orange])
                    .fixedSize()
                Text(Policy.help(access, kind: kind)).font(.caption)
                    .foregroundStyle(kind == .mac && access == "auto" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if let b = entry?.activeBypass { bypassNote(b) }
            }
            Spacer()
        }
        if let entry, !entry.library, access != "never", kind != .value {
            row("Only for") { LimitsEditor(entry: entry) }
        }
        if kind == .login { row("2FA") { twoFAValue } }
        if !kind.eachUse { row("Scripts") {
            Toggle("", isOn: scriptsBinding).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(scripts ? "otto run can pass its values to programs" : "otto run can't pass its values to programs")
                    .foregroundStyle(.secondary)
                if scripts {
                    // the program gets the value itself: it can print it, and then the agent has read it
                    Text("a program the agent runs could print them, so the agent can end up seeing them. turn on only for entries that's fine for.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        } }
        if let entry, !entry.library, access != "never", kind != .value { row("Notifications") {
            Toggle("", isOn: Binding(
                get: { !entry.quiet },
                set: { on in Task { _ = try? await engine.upsert(["id": entry.id, "quiet": !on]) } }
            )).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.quiet ? "no notification when agents use it without asking" : "a notification when agents use it without asking, with Stop")
                    .foregroundStyle(.secondary)
                if entry.quiet {
                    Text("it still shows in Activity, but you won't get a Stop button for it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        } }
    }

    /// Bypass needs a saved login (its consent is sealed to the entry), so a new one doesn't offer it.
    private var accessOptions: [(String, String)] {
        guard let entry, !entry.library, kind != .value else { return Policy.options(kind) }
        return Policy.options(kind) + [Policy.bypass]
    }

    /// cards ask every time, whatever was saved before
    private var access: String { entry?.activeBypass != nil ? "bypass" : !kind.offersAuto && policy == "auto" ? "ask" : policy }

    /// Bypass goes on and off right away, also while editing: on through the consent window (Touch ID),
    /// off by picking any other access, which then applies like before.
    private var accessBinding: Binding<String> {
        Binding(get: { access }, set: { p in
            // root without asking: only the person at the Mac can switch that on (not an agent clicking around)
            if kind == .mac, p == "auto", access != "auto" {
                Task {
                    guard await Auth.confirm("let agents run sudo commands without asking") != nil else { return }
                    if let entry, entry.activeBypass != nil { try? await engine.bypassOff(entry.id) }
                    policyBinding.wrappedValue = p
                }
                return
            }
            guard let entry else {
                policyBinding.wrappedValue = p
                return
            }
            if p == "bypass" {
                if entry.activeBypass == nil { Task { await EntryActions.turnOnBypass(entry) } }
                return
            }
            if entry.activeBypass != nil { Task { try? await engine.bypassOff(entry.id) } }
            policyBinding.wrappedValue = p
        })
    }

    /// When and how the user said yes.
    private func bypassNote(_ b: Bypass) -> some View {
        let until = b.until.map { "until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "until you turn it off"
        let asked = b.askedBy.map { ", \($0) asked" } ?? ""
        return Label {
            Text("you turned it on \(b.at.formatted(.relative(presentation: .named))) with \(b.authLabel), \(until)\(asked)")
        } icon: {
            Image(systemName: "checkmark.seal.fill")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help("“\(b.statement)”\(b.reason.map { "\n\(b.askedBy ?? "the agent"): \($0)" } ?? "")")
    }

    /// In view mode a change is saved right away; while editing it's part of the draft.
    private var policyBinding: Binding<String> {
        Binding(get: { policy }, set: { p in
            policy = p
            if !editing, let entry { Task { _ = try? await engine.upsert(["id": entry.id, "policy": p]) } }
        })
    }

    private var scriptsBinding: Binding<Bool> {
        Binding(get: { scripts }, set: { s in
            scripts = s
            if !editing, let entry { Task { _ = try? await engine.upsert(["id": entry.id, "scripts": s]) } }
        })
    }

    @ViewBuilder private var twoFAValue: some View {
        if !editing {
            Image(systemName: twoFASymbol).foregroundStyle(.secondary).frame(width: 16)
            Text(twoFactorText)
            if let detail = twoFactorDetail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
        } else if let t = entry?.totp, !replacingOTP, !removeOTP {
            Image(systemName: "number").foregroundStyle(.secondary).frame(width: 16)
            Text([t.issuer, t.account].compactMap { $0 }.joined(separator: ", ").ifEmpty("authenticator code"))
            Spacer()
            Button("Replace") { replacingOTP = true }.buttonStyle(SoftButton()).controlSize(.small)
            Button("Remove") { removeOTP = true }.buttonStyle(SoftButton()).foregroundStyle(.red)
        } else if removeOTP {
            Text("the 2FA code will be removed").foregroundStyle(.red)
            Spacer()
            Button("Undo") { removeOTP = false }.buttonStyle(SoftButton())
        } else {
            TwoFAPicker(hints: [sites, name, username], kind: $twoFactor, otp: $otp, fromID: $otpFrom)
        }
    }

    private var twoFASymbol: String {
        if entry?.totp != nil { return "number" }
        switch entry?.twoFactor {
        case "delivered": return "message"
        case "none": return "minus.circle"
        default: return "questionmark.circle"
        }
    }

    private var twoFactorText: String {
        if entry?.totp != nil { return "Authenticator code" }
        switch entry?.twoFactor {
        case "delivered": return "Sent by SMS or email"
        case "none": return "None"
        default: return "Not set"
        }
    }

    private var twoFactorDetail: String? {
        if entry?.totp != nil { return "otto fills it" }
        switch entry?.twoFactor {
        case "delivered": return "agents ask you for it"
        case "none": return nil
        default: return "agents ask you if the site wants one"
        }
    }

    private var editFooter: some View {
        HStack(alignment: .firstTextBaseline) {
            if let entry {
                Button("Delete \(entry.name)…") { EntryActions.confirmDelete(entry) }
                    .buttonStyle(.plain).foregroundStyle(.red)
            }
            Spacer()
            if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing) }
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func recent(_ entry: Entry) -> some View {
        let mine = Array(engine.activity.filter { $0.entry?.caseInsensitiveCompare(entry.name) == .orderedSame }.prefix(5))
        if !mine.isEmpty {
            Block(title: "Recent activity") {
                Button("See all") { ui.go(.activity) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            } content: {
                ForEach(ActivityBatch.of(mine)) { b in ActivityRow(batch: b, onEntryPage: true) }
            }
        }
    }

    // MARK: pieces

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            HStack(spacing: 6) { content() }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: logic

    private func beginEdit() {
        name = entry?.name ?? ""
        username = entry?.username ?? ""
        sites = entry?.sites.joined(separator: ", ") ?? ""
        apps = entry?.apps.joined(separator: ", ") ?? ""
        policy = entry?.policy ?? kind.policy
        scripts = entry?.scripts ?? (kind == .key)
        twoFactor = entry?.twoFactor.flatMap { $0 == "app" ? nil : $0 } ?? "app"
        values = [:]
        loaded = [:]
        showing = []
        siteDraft = ""
        guessed = [:]
        valueHidden = entry?.secret ?? true
        commands = entry?.commands ?? []
        about = ""
        aboutLoaded = ""
        if let v = entry?.value {
            values["value"] = v
            loaded["value"] = v
        }
        if entry == nil, kind == .mac { name = "Mac password" }
        if entry == nil, let draft = ui.previewDraft {
            // dev aid (OTTO_PREVIEW): a new entry already typed in
            ui.previewDraft = nil
            for (k, v) in draft {
                switch k {
                case "name": name = v
                case "sites": sites = v
                case "focus": DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .secret(v) }
                default: values[k] = v
                }
            }
        }
        if let e = entry, let fields = Self.plainFields[e.kindValue] {
            if e.kindValue == .card {
                values["expiry"] = e.card?.expiry ?? ""
                loaded["expiry"] = values["expiry"]
            }
            Task {
                for f in fields {
                    let v = await engine.secret(e.id, f) ?? ""
                    // unless something was typed there meanwhile
                    if f == "notes" {
                        if about == aboutLoaded { about = v }
                        aboutLoaded = v
                        continue
                    }
                    if (values[f] ?? "") == (loaded[f] ?? "") { values[f] = v }
                    loaded[f] = v
                }
            }
        }
        password = ""
        showPassword = false
        revealed = nil
        otp = ""
        otpFrom = nil
        removeOTP = false
        replacingOTP = false
        error = nil
        original = snapshot
        ui.guardian.isDirty = { dirty }
        ui.guardian.save = { save() }
        DispatchQueue.main.async { focus = entry == nil ? .name : nil }
    }

    /// With a saved password and nothing typed, the eye shows the saved one after Touch ID.
    private func toggleDraftPassword() async {
        if showPassword {
            showPassword = false
            return
        }
        if let e = entry, e.hasPassword, password.isEmpty {
            guard await Auth.evaluate("show the password for \(e.name)"),
                  let p = await engine.secret(e.id, "password") else { return }
            password = p
            revealed = p
        }
        showPassword = true
    }

    private func save() {
        guard canSave else { return }
        // a website still being typed counts, if it is one
        let typed = siteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            let parts = typed.split(whereSeparator: { ", \n\t;".contains($0) }).map(String.init)
            let domains = parts.compactMap(Domain.normalize)
            guard domains.count == parts.count else {
                error = "“\(parts.first { Domain.normalize($0) == nil } ?? typed)” isn't a website"
                return
            }
            sites = (split(sites) + domains.filter { !split(sites).contains($0) }).joined(separator: ", ")
            siteDraft = ""
        }
        var p: [String: Any] = [
            "name": effectiveName,
            "kind": kind.rawValue,
            "policy": !kind.offersAuto && policy == "auto" ? "ask" : policy,
            "scripts": scripts,
        ]
        if let e = entry { p["id"] = e.id }
        switch kind {
        case .login:
            p["username"] = username
            p["sites"] = split(sites)
            p["apps"] = split(apps)
            if !password.isEmpty && password != revealed { p["password"] = password }
            let o = otp.trimmingCharacters(in: .whitespacesAndNewlines)
            if twoFactor != "app" {
                p["two_factor"] = twoFactor
                if entry?.totp != nil { p["otp"] = "" }
            } else {
                p["two_factor"] = ""
                if !o.isEmpty { p["otp"] = o } else if let f = otpFrom { p["otp_from"] = f } else if removeOTP { p["otp"] = "" }
            }
            // an imported code becomes a normal login once it has somewhere to be used
            if entry?.library == true, !split(sites).isEmpty || !split(apps).isEmpty || !password.isEmpty { p["library"] = false }
        case .card:
            var f = changed
            if let n = f["number"] {
                guard CardInfo.luhn(n) else {
                    error = "that card number doesn't add up. check the digits"
                    return
                }
                f["number"] = CardInfo.grouped(n)
            }
            if let e = f["expiry"], !e.isEmpty {
                guard let (m, y) = CardInfo.parse(e) else {
                    error = "the expiry should look like 08/28"
                    return
                }
                f["expiry"] = String(format: "%02d/%02d", m, y % 100)
            }
            p["fields"] = f
            p["sites"] = split(sites)
        case .key:
            p["fields"] = changed
            p["sites"] = split(sites)
            if about != aboutLoaded { p["notes"] = about }
        case .value:
            if !changed.isEmpty { p["fields"] = changed }
            p["secret"] = valueHidden
            p["commands"] = commands
            if about != aboutLoaded { p["notes"] = about }
        case .note:
            if let n = changed["notes"] { p["notes"] = n }
        case .mac:
            if !password.isEmpty && password != revealed { p["password"] = password }
        }
        error = nil
        busy = true
        Task {
            // what's hidden behind Touch ID doesn't come out into the open without it
            if kind == .value, let e = entry, e.secret, !valueHidden, await !Auth.evaluate("stop hiding the value of \(e.name)") {
                busy = false
                return
            }
            // a typo here would only show up as a failed sudo
            if kind == .mac, let pw = p["password"] as? String, !(await MacAccount.check(pw)) {
                error = "that isn't this Mac's password"
                busy = false
                return
            }
            do {
                let saved = try await engine.upsert(p)
                await engine.refresh()
                ui.guardian.isDirty = { false }
                ui.editing = false
                if entry == nil, let saved { ui.route = .entry(saved.id) }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private struct RunningApp {
        let id: String
        let name: String
    }

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { RunningApp(id: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func addApp(_ id: String) {
        var list = split(apps)
        if !list.contains(id) { list.append(id) }
        apps = list.joined(separator: ", ")
    }

    private func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }

    static func generate() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = String(bytes.map { chars[Int($0) % chars.count] })
        // 4 groups of 5 with dashes: easy to read, still ~110 bits
        return stride(from: 0, to: 20, by: 5).map { i in String(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 5)]) }.joined(separator: "-")
    }
}

/// A site name that opens the site; underlined under the pointer.
struct LinkButton: View {
    let title: String
    let url: URL?
    var primary = false
    @State private var hover = false

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Text(title).underline(hover)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).opacity(hover ? 1 : 0.6)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .onHover { hover = $0 }
        .help(url?.absoluteString ?? "")
    }
}

/// Optional limits on an entry: only agents working in some project folders, only some agents. Saved right
/// away. Outside them, the entry is as good as "never" to an agent.
private struct LimitsEditor: View {
    let entry: Entry
    @State private var engine = Engine.shared

    /// agents otto can verify by their signature: a limit to an agent only counts for those
    private static let agents = ["claude", "codex", "opencode", "cursor", "zed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(entry.agents, id: \.self) { a in
                    chip(Text(a).foregroundStyle(AgentStyle.color(a)), symbol: nil) { save(agents: entry.agents.filter { $0 != a }) }
                }
                ForEach(entry.folders, id: \.self) { f in
                    chip(Text(f), symbol: "folder") { save(folders: entry.folders.filter { $0 != f }) }
                }
                Menu {
                    Button("A Project Folder…") { pickFolder() }
                    Section("Agent") {
                        ForEach(Self.agents.filter { !entry.agents.contains($0) }, id: \.self) { a in
                            Button(a) { save(agents: entry.agents + [a]) }
                        }
                    }
                } label: {
                    Label(entry.folders.isEmpty && entry.agents.isEmpty ? "Add a Limit" : "Add", systemImage: "plus")
                        .font(.callout)
                }
                .menuStyle(.button)
                .buttonStyle(SoftButton())
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
    }

    private var help: String {
        let who = entry.agents.isEmpty ? "any agent" : "only " + list(entry.agents)
        if entry.folders.isEmpty && entry.agents.isEmpty { return "any agent, working in any folder. optional: limit it to some projects or agents." }
        let where_ = entry.folders.isEmpty ? "in any folder" : "working in " + list(entry.folders, or: true) + " (or inside)"
        return "\(who), \(where_). to every other agent it's as if it's set to never."
    }

    private func list(_ items: [String], or: Bool = false) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
    }

    private func chip(_ label: Text, symbol: String?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            label.lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("remove this limit")
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Palette.field, in: Capsule())
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Limit to This Folder"
        panel.message = "agents working in this folder, or one inside it, can use \(entry.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // the service compares with the agent's folder, which it writes with ~ for home
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        if !entry.folders.contains(path) { save(folders: entry.folders + [path]) }
    }

    private func save(folders: [String]? = nil, agents: [String]? = nil) {
        var p: [String: Any] = ["id": entry.id]
        if let folders { p["folders"] = folders }
        if let agents { p["agents"] = agents }
        Task { _ = try? await engine.upsert(p) }
    }
}
