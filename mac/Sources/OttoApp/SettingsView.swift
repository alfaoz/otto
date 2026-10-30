import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// A command or path with a copy button.
struct CopyLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 8)
            CopyButton(help: "copy") { text }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The recovery key, big, with copy and save-to-file (and hide, where it can be shown again).
struct KeyCard: View {
    let key: String
    var hide: (() -> Void)?
    @State private var copied = false
    @State private var savedTo: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(key)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .kerning(0.6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button {
                    Setup.copy(key, concealed: true)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .opacity(copied ? 0 : 1)
                        .overlay { if copied { Text("copied").foregroundStyle(.green) } }
                        .frame(minWidth: 64)
                }
                .buttonStyle(SoftButton())
                Button {
                    if let url = RecoveryKit.save(key: key) { savedTo = url.lastPathComponent }
                } label: {
                    Label(savedTo == nil ? "Save as file…" : "Saved", systemImage: savedTo == nil ? "arrow.down.doc" : "checkmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(SoftButton())
                if let hide {
                    Button(action: hide) { Label("Hide", systemImage: "eye.slash") }
                        .buttonStyle(SoftButton())
                }
            }
            if let savedTo {
                Text("saved \(savedTo)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

enum RecoveryKit {
    /// Asks where to save a small text file with the key and how to use it.
    @MainActor
    static func save(key: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "otto recovery key.txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let date = Date().formatted(date: .long, time: .omitted)
        let text = """
        otto recovery key
        =================

        \(key)

        this key opens your otto vault:
          ~/Library/Application Support/otto/vault.kdbx

        the vault is a normal KeePass file. to open it in KeePassXC, Strongbox or
        KeePassium, use the key above as the password, exactly as written (with the dashes).

        on a new Mac: install otto, put vault.kdbx in that folder, and enter this key
        when otto asks for it.

        saved \(date). keep it somewhere safe: your password manager, or printed.

        """
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}

/// otto ▸ Settings: General, Browser, Agents, Remote, Vault.
struct SettingsView: View {
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Browser", systemImage: "globe", value: "browser") { BrowserSettings() }
            Tab("Agents", systemImage: "terminal", value: "agents") { AgentSettings() }
            Tab("Remote", systemImage: "iphone.radiowaves.left.and.right", value: "remote") { RemoteSettings() }
            Tab("Vault", systemImage: "lock", value: "vault") { VaultSettings() }
        }
        .frame(width: 560, height: 470)
        .focusEffectDisabled()
    }
}

private struct GeneralSettings: View {
    @State private var atLogin = Setup.launchAtLogin
    @State private var loginProblem: String?
    @State private var axOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @AppStorage(Prefs.menuBarKey) private var showMenuBar = true
    @AppStorage(Prefs.askBeforeQuitKey) private var askBeforeQuit = true
    @State private var notices: NoticeState = .loading

    private enum NoticeState {
        case loading, on, off, notAsked
        init(_ allowed: Bool?) { self = allowed == nil ? .notAsked : allowed! ? .on : .off }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open otto at login", isOn: $atLogin)
                    .onChange(of: atLogin) { _, v in loginProblem = Setup.setLaunchAtLogin(v); atLogin = Setup.launchAtLogin }
                Toggle("Ask before quitting", isOn: $askBeforeQuit)
            } footer: {
                Text(loginProblem ?? "agents can only use otto while it's running. closing the window keeps it running; quitting stops it.")
                    .foregroundStyle(loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Section {
                Toggle("Show otto in the menu bar", isOn: $showMenuBar)
            }
            Section {
                LabeledContent {
                    switch notices {
                    case .on:
                        Label("On", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                    case .off:
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.alfaoz.otto")!)
                        }
                    case .notAsked:
                        Button("Turn On") { Task { notices = NoticeState(await Notices.shared.ask()) } }
                    case .loading:
                        EmptyView()
                    }
                } label: {
                    Text("Notifications")
                    Text("when an agent uses something without asking you right then (Auto, bypass, an earlier Touch ID yes), with Stop to cut it off")
                }
            }
            UpdateSettings()
            WaitSettings()
            Section("Permissions") {
                permission("Accessibility", "to type a password into a Mac app", axOK, "Privacy_Accessibility")
                permission("Screen Recording", "to read a 2FA QR code from the screen", screenOK, "Privacy_ScreenCapture")
            }
            Section {
                Button("Quit otto") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .task { notices = NoticeState(await Notices.shared.allowed()) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            axOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
            Task { notices = NoticeState(await Notices.shared.allowed()) }
        }
    }

    private func permission(_ name: String, _ why: String, _ ok: Bool, _ anchor: String) -> some View {
        LabeledContent {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
                }
            }
        } label: {
            Text(name)
            Text(why)
        }
    }
}

/// Settings → General: how long otto waits for the user. The service keeps these, in the vault.
private struct WaitSettings: View {
    private struct Wait: Identifiable {
        let key: String
        let label: String
        var hint: String?
        var id: String { key }
    }

    private static let minutes: [Double] = [1, 2, 3, 5, 10, 15, 30, 60]
    private static let all = [
        Wait(key: "blanks", label: "Commands with blanks", hint: "time to go and find what to type"),
        Wait(key: "save", label: "Saving a login"),
        Wait(key: "approve", label: "Other requests", hint: "commands, changes to a secret, new sites, bypass"),
        Wait(key: "mac_password", label: "Mac password", hint: "the first time sudo needs it"),
        Wait(key: "browser", label: "A new browser"),
        Wait(key: "phone", label: "Links to your phone"),
    ]

    @State private var waits: [String: Int] = [:]

    private func binding(_ key: String) -> Binding<Int> {
        Binding(get: { waits[key] ?? 0 }, set: { v in
            waits[key] = v
            Task { _ = try? await Engine.shared.call("set_waits", ["waits": waits]) }
        })
    }

    private func title(_ minutes: Double) -> String {
        let n = minutes == minutes.rounded() ? String(Int(minutes)) : String(minutes)
        return minutes == 1 ? "1 minute" : "\(n) minutes"
    }

    var body: some View {
        Section {
            if !waits.isEmpty {
                ForEach(Self.all) { w in
                    Picker(selection: binding(w.key)) {
                        ForEach(Self.minutes, id: \.self) { m in Text(title(m)).tag(Int(m * 60)) }
                        // a time that isn't one of those (the Mac password's usual 4.5 minutes) still shows
                        if let now = waits[w.key], !Self.minutes.contains(Double(now) / 60) { Text(title(Double(now) / 60)).tag(now) }
                    } label: {
                        Text(w.label)
                        if let hint = w.hint { Text(hint) }
                    }
                }
            }
        } header: {
            Text("How long otto waits for you")
        } footer: {
            Text("when the time's up, the window closes and the agent hears that nobody answered.")
                .foregroundStyle(.secondary)
        }
        .task { waits = (try? await Engine.shared.call("waits") as? [String: Int]) ?? [:] }
    }
}

private struct BrowserSettings: View {
    @State private var engine = Engine.shared
    @State private var installed = KnownBrowser.installed
    /// other browsers the user allowed: [name, bundle, signer, team]
    @State private var trusted: [[String: String]] = []

    private var missing: Bool { installed.contains { !$0.connected(engine.browsers) } }

    var body: some View {
        Form {
            Section {
                if installed.isEmpty {
                    Text("no Chromium browser found. otto works with Chrome, Brave, Edge, Arc, Dia, Vivaldi, Opera, Comet, ChatGPT Atlas and other Chromium browsers.")
                        .foregroundStyle(.secondary)
                }
                ForEach(installed) { b in browserRow(b) }
            } header: {
                Text("Browsers")
            } footer: {
                Text("the extension fills a login only on that login's own website, and only when an agent asks.")
                    .foregroundStyle(.secondary)
            }
            // a release installs the extension from the Chrome Web Store (the button in its row); a dev build loads it unpacked
            if missing && !Updates.shared.enabled {
                Section("Install the extension in a browser") {
                    step(1, "Open its extensions page (the button next to it above)") { EmptyView() }
                    step(2, "Turn on Developer mode") { EmptyView() }
                    step(3, "Click Load unpacked and pick otto's extension folder") {
                        Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([Setup.extensionDir]) }
                    }
                    CopyLine(text: Setup.extensionDir.path)
                }
            }
            if !trusted.isEmpty {
                Section {
                    ForEach(trusted, id: \.self) { b in
                        LabeledContent {
                            Button("Forget") { Task { await forget(b["bundle"] ?? "") } }
                        } label: {
                            Text(b["name"] ?? "?")
                            Text("signed by \(b["signer"] ?? "?") (\(b["team"] ?? ""))")
                        }
                    }
                } header: {
                    Text("Other browsers you allowed")
                } footer: {
                    Text("a browser otto doesn't know asks you once, with Touch ID. forget it and it has to ask again.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            installed = KnownBrowser.installed
            Setup.registerBrowserHelper()
        }
        .task(id: engine.browsers) { await load() }
    }

    private func browserRow(_ b: KnownBrowser) -> some View {
        let on = b.connected(engine.browsers)
        return LabeledContent {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(on ? Color.green : .orange).frame(width: 7, height: 7)
                    Text(on ? "connected" : "not connected").foregroundStyle(.secondary)
                }
                if !on {
                    if Updates.shared.enabled {
                        Button("Add Extension") { b.openExtensionListing() }
                    } else {
                        Button("Extensions Page") { b.openExtensionsPage() }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let url = b.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                }
                Text(b.name)
            }
        }
    }

    private func load() async {
        let r = try? await engine.call("browsers") as? [String: Any]
        trusted = (r?["trusted"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
    }

    private func forget(_ bundle: String) async {
        _ = try? await engine.call("forget_browser", ["bundle": bundle])
        await load()
    }

    private func step<A: View>(_ n: Int, _ text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Palette.field, in: Circle())
            Text(text)
            Spacer()
            action()
        }
    }
}

private struct AgentSettings: View {
    @State private var engine = Engine.shared
    @State private var plugin = Setup.claudePluginInstalled
    @State private var forgot = false
    @State private var others: [OtherAgent] = []
    @State private var connecting: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("otto plugin") {
                    if plugin {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("not installed").foregroundStyle(.secondary)
                    }
                }
                if !plugin {
                    CopyLine(text: "/plugin marketplace add alfaoz/otto")
                    CopyLine(text: "/plugin install otto@otto")
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("MCP tools plus a skill that teaches Claude how to log in, get codes and ask you to save a login.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(others.filter { $0.installed || $0.connected }) { a in
                    LabeledContent(a.name) {
                        if a.connected {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(connecting == a.id ? "Connecting…" : "Connect") {
                                Task {
                                    connecting = a.id
                                    problem = await OtherAgent.connect(a.id)
                                    others = await OtherAgent.list()
                                    connecting = nil
                                }
                            }
                            .disabled(connecting != nil)
                        }
                    }
                }
                LabeledContent("Anything else") { CopyLine(text: "otto mcp").frame(maxWidth: 220) }
            } header: {
                Text("Other agents")
            } footer: {
                Text(problem ?? "Connect adds otto's MCP server to that agent's settings and keeps a copy of the old file. Restart the agent afterwards. Any other agent can run otto mcp as an MCP server, or use the otto command.")
                    .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            Section {
                LabeledContent {
                    Button(forgot ? "Forgotten" : "Forget All") {
                        Task {
                            _ = try? await engine.call("forget_approvals")
                            forgot = true
                        }
                    }
                    .disabled(forgot)
                } label: {
                    Text("Touch ID approvals")
                    Text("one approval lets an agent use that entry for 10 minutes")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { plugin = Setup.claudePluginInstalled }
        .task { others = await OtherAgent.list() }
    }
}

/// An agent `otto connect` knows how to set up.
struct OtherAgent: Identifiable {
    let id: String
    let name: String
    let installed: Bool
    let connected: Bool

    private static var exe: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/otto") }

    private static func run(_ args: [String]) async -> (ok: Bool, out: String, err: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            guard (try? p.run()) != nil else { return (false, "", "otto isn't in the app bundle") }
            let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
    }

    static func list() async -> [OtherAgent] {
        let r = await run(["connect", "--json"])
        guard let list = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { j in
            guard let id = j["id"] as? String, let name = j["name"] as? String else { return nil }
            return OtherAgent(id: id, name: name, installed: j["installed"] as? Bool ?? false, connected: j["connected"] as? Bool ?? false)
        }
    }

    /// nil when it worked, otherwise what went wrong
    static func connect(_ id: String) async -> String? {
        let r = await run(["connect", id])
        return r.ok ? nil : r.err.replacingOccurrences(of: "otto: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct VaultSettings: View {
    @State private var key: String?
    @AppStorage(Prefs.autoLockKey) private var autoLock = "never"

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    HStack(spacing: 8) {
                        Text("vault.kdbx").foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Engine.vaultURL]) }
                    }
                }
                LabeledContent("Format", value: "KeePass (KDBX 4)")
                LabeledContent("Key", value: "in your login keychain")
            }
            Section {
                if let key {
                    KeyCard(key: key) { self.key = nil }
                } else {
                    LabeledContent {
                        Button("Show…") {
                            Task { if await Auth.evaluate("show your vault’s recovery key") { key = Keychain.read() } }
                        }
                    } label: {
                        Text("Recovery key")
                        Text("needs Touch ID")
                    }
                }
            } footer: {
                Text("it opens the vault in KeePassXC, Strongbox or KeePassium, and gets it back on a new Mac or if your keychain is lost. keep a copy somewhere safe.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Lock otto", selection: $autoLock) {
                    Text("Never").tag("never")
                    Text("When the Mac sleeps or locks").tag("sleep")
                    Text("After 5 minutes away").tag("5")
                    Text("After 15 minutes away").tag("15")
                    Text("After 1 hour away").tag("60")
                }
            } footer: {
                Text(autoLock == "never"
                     ? "optional. otto stays unlocked while it runs."
                     : "away: no keys or clicks on the Mac and no agent using otto. while it's locked, an agent that needs otto makes it ask you for Touch ID; your phone can't unlock it, so remote approvals wait until you're back.")
                    .foregroundStyle(.secondary)
            }
            BackupsSection()
        }
        .formStyle(.grouped)
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State private var engine = Engine.shared
    @State private var atLogin = true
    @State private var promised = false
    @State private var plugin = Setup.claudePluginInstalled
    private let key = Keychain.read() ?? "?"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("otto is ready").font(.system(size: 22, weight: .bold))
                    Text("your agents can log in and get 2FA codes without ever seeing a password.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your recovery key").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                KeyCard(key: key)
                Text("it's in your keychain already. keep a copy somewhere safe too: it opens your vault in any KeePass app and gets it back on a new Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Next").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Card {
                    next("Install the browser extension", done: !engine.browsers.isEmpty, tab: "browser")
                    next("Add otto to Claude Code", done: plugin, tab: "agents")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open otto at login", isOn: $atLogin)
                Toggle("i pinky promise i got my keys somewhere safe.", isOn: $promised)
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Done") {
                    Setup.launchAtLogin = atLogin
                    done()
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!promised)
            }
        }
        .padding([.horizontal, .bottom], 26)
        .padding(.top, 2)
        .frame(width: 460)
    }

    private func next(_ title: String, done: Bool, tab: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            Text(title)
            Spacer()
            if !done {
                Button("Set up") {
                    Setup.launchAtLogin = atLogin
                    Windows.shared.showSettings(tab: tab)
                }
                .buttonStyle(SoftButton())
                .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
