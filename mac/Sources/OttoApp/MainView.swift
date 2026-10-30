import AppKit
import SwiftUI

/// What the detail side of the main window shows.
enum Route: Hashable {
    case activity
    case entry(String)
    /// filling in a new login
    case new
    /// deleted entries
    case trash
}

/// The main window's state. Editing happens in place, in the detail pane.
@MainActor @Observable
final class UIState {
    static let shared = UIState()

    var route: Route = .activity
    /// editing the selected entry (a new one is always being edited)
    var editing = false
    /// what the new entry is
    var newKind: Kind = .login
    /// where Cancel goes back to from a new login
    @ObservationIgnored private var before: Route = .activity
    @ObservationIgnored let guardian = CloseGuard()
    /// dev aid (OTTO_PREVIEW): values a new entry starts with
    @ObservationIgnored var previewDraft: [String: String]?

    var isEditing: Bool { editing || route == .new }

    func go(_ r: Route) {
        guard route != r, leave() else { return }
        route = r
    }

    func startEdit(_ e: Entry?, kind: Kind = .login) {
        guard leave() else { return }
        if let e {
            route = .entry(e.id)
            editing = true
        } else {
            if route != .new { before = route }
            newKind = kind
            route = .new
            editing = false
        }
        Self.bringMainWindowForward()
    }

    /// Ends editing; with unsaved changes it asks first. Returns false if the user keeps editing.
    func leave() -> Bool {
        guard isEditing else { return true }
        if guardian.isDirty() {
            let alert = NSAlert()
            alert.messageText = "Save your changes?"
            alert.informativeText = "are you sure you want to leave without saving? what you typed will be lost."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Keep Editing")
            alert.buttons[1].hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guardian.save?()
                return false
            case .alertSecondButtonReturn:
                break
            default:
                return false
            }
        }
        doneEditing()
        return true
    }

    /// After a save, a delete, or Don't Save.
    func doneEditing() {
        editing = false
        if route == .new { route = before }
        guardian.isDirty = { false }
    }

    static func bringMainWindowForward() {
        Presence.showMain()
    }
}

/// The main window: everything in the sidebar (with live codes), the selected thing on the right.
struct MainView: View {
    @State private var engine = Engine.shared
    @State private var ui = UIState.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    if !ui.isEditing {
                        ToolbarItem {
                        Menu {
                            NewMenu()
                            Divider()
                            Button("Import Logins and 2FA Codes…", systemImage: "square.and.arrow.down") { Windows.shared.showImport() }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .menuIndicator(.hidden)
                        .help("add a login, card, key, note, value or your Mac password, or import 2FA codes")
                        }
                    }
                }
        }
        .navigationTitle("otto")
        .toolbar(removing: .title)
        .onAppear {
            engine.panelVisible = true
            SettingsOpener.action = openSettings
            // with the menu bar icon hidden, this is the only place that can reopen the window later
            if Presence.openMain == nil { Presence.openMain = openWindow }
        }
        .onDisappear { engine.panelVisible = false }
        .focusEffectDisabled()
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch engine.state {
        case .starting:
            ProgressView().controlSize(.small)
        case .needsKey(let why):
            RecoveryPrompt(message: why).frame(maxWidth: 420)
        case .locked:
            Placeholder(symbol: "lock.fill", title: "otto is locked", detail: "agents can't use it until you unlock it. when one needs it, otto asks you for Touch ID.",
                        action: ("Unlock", { Task { await engine.unlock(reason: "unlock itself") } }))
        case .failed(let why):
            Placeholder(symbol: "exclamationmark.triangle", title: "otto couldn't start", detail: why, action: ("Try Again", { engine.retry() }))
        case .ready:
            switch ui.route {
            case .activity:
                ActivityView()
            case .new:
                EntryDetail(entry: nil).id("new")
            case .trash:
                TrashView()
            case .entry(let id):
                if let e = engine.entries.first(where: { $0.id == id }) {
                    EntryDetail(entry: e).id(id)
                } else {
                    ActivityView()
                }
            }
        }
    }
}

struct Sidebar: View {
    @State private var engine = Engine.shared
    @State private var ui = UIState.shared
    @State private var query = ""
    /// the tile that's open: only that shelf shows in the list
    @AppStorage("sidebar.shelf") private var shelfRaw = ""
    /// the sections the user folded
    @AppStorage("sidebar.folded") private var folded = ""

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private var shelf: Shelf? { q.isEmpty ? Shelf(rawValue: shelfRaw) : nil }

    private func matches(_ e: Entry) -> Bool {
        q.isEmpty || ([e.name, e.username ?? "", e.totp?.issuer ?? "", e.totp?.account ?? "", e.value ?? ""] + e.sites + e.apps + e.commands)
            .contains { $0.lowercased().contains(q) }
    }

    /// A shelf's rows. In the full list a code on a login stays with the login.
    private func entries(_ s: Shelf) -> [Entry] {
        engine.entries.filter { s.holds($0) && matches($0) && (s != .codes || shelf == .codes || $0.library) }
    }

    private func isOpen(_ s: Shelf) -> Binding<Bool> {
        if !q.isEmpty { return .constant(true) }
        return Binding(get: { !folded.split(separator: ",").contains(Substring(s.rawValue)) }, set: { open in
            var set = Set(folded.split(separator: ",").map(String.init))
            if open { set.remove(s.rawValue) } else { set.insert(s.rawValue) }
            folded = set.sorted().joined(separator: ",")
        })
    }

    /// the list's selection; changing it goes through UIState so unsaved edits are asked about
    private var selection: Binding<Route?> {
        Binding(get: { ui.route }, set: { r in if let r { ui.go(r) } })
    }

    var body: some View {
        List(selection: selection) {
            if q.isEmpty {
                Label {
                    Text("Activity")
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
                .badge(engine.unseen)
                .tag(Route.activity)
            }
            if ui.route == .new {
                NewRow().tag(Route.new)
            }
            if let shelf {
                let list = entries(shelf)
                ForEach(list) { e in EntryRow(entry: e).tag(Route.entry(e.id)) }
                if list.isEmpty { EmptyShelf(shelf: shelf).selectionDisabled() }
            } else {
                ForEach(Shelf.allCases) { s in
                    let list = entries(s)
                    if !list.isEmpty {
                        Section(isExpanded: isOpen(s)) {
                            ForEach(list) { e in EntryRow(entry: e).tag(Route.entry(e.id)) }
                        } header: {
                            Text(s.title)
                        }
                    }
                }
                if q.isEmpty && !engine.trash.isEmpty {
                    Section {
                        Label("Recently Deleted", systemImage: "trash")
                            .badge(engine.trash.count)
                            .tag(Route.trash)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .overlay {
            if !q.isEmpty && engine.entries.allSatisfy({ !matches($0) }) {
                ContentUnavailableView.search(text: query)
            }
        }
        .contextMenu(forSelectionType: Route.self) { routes in
            if let e = entry(routes) { EntryMenu(entry: e, code: engine.codes[e.id]) }
        } primaryAction: { routes in
            if let e = entry(routes) { ui.startEdit(e) }
        }
        .onCopyCommand {
            // ⌘C on an entry: its 2FA code, else its username
            guard case .entry(let id) = ui.route, let e = engine.entries.first(where: { $0.id == id }) else { return [] }
            guard let v = engine.codes[id]?.code ?? e.username else { return [] }
            return [NSItemProvider(object: v as NSString)]
        }
        .safeAreaBar(edge: .top) {
            if q.isEmpty, engine.state == .ready { ShelfGrid(open: $shelfRaw) }
        }
        .safeAreaBar(edge: .bottom) { StatusFooter() }
    }

    private func entry(_ routes: Set<Route>) -> Entry? {
        guard case .entry(let id)? = routes.first else { return nil }
        return engine.entries.first { $0.id == id }
    }
}

/// What's in the vault at a glance, a tile per shelf. A click shows only that shelf; another click, everything.
private struct ShelfGrid: View {
    @Binding var open: String
    @State private var engine = Engine.shared

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Shelf.allCases) { s in
                ShelfTile(shelf: s, count: engine.entries.count(where: s.holds), selected: open == s.rawValue) {
                    open = open == s.rawValue ? "" : s.rawValue
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

private struct ShelfTile: View {
    let shelf: Shelf
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: shelf.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(shelf.tint))
                    Spacer(minLength: 2)
                    Text("\(count)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }
                Text(shelf.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(shelf.tint) : AnyShapeStyle(hovering ? Palette.field : Palette.card), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.clear : Palette.cardStroke))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(shelf.title), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "show everything" : "show only \(shelf.title.lowercased())")
    }
}

/// An open tile with nothing in it says how to put something there.
private struct EmptyShelf: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shelf.empty).foregroundStyle(.secondary)
            if let k = shelf.newKind {
                Button(k == .value ? "Remember a Value…" : "New \(k.title)…") { UIState.shared.startEdit(nil, kind: k) }
                    .buttonStyle(SoftButton())
            } else {
                Button("Import…") { Windows.shared.showImport() }
                    .buttonStyle(SoftButton())
            }
        }
        .padding(.vertical, 6)
    }
}

/// One entry in the sidebar: icon, name, who it's for, and the live code if it has one.
struct EntryRow: View {
    let entry: Entry
    @State private var engine = Engine.shared

    private var code: Code? { entry.totp == nil ? nil : engine.codes[entry.id] }
    private var live: Activity? { engine.live[entry.name.lowercased()] }

    private var subtitle: String {
        if entry.library { return entry.totp?.account ?? entry.username ?? "" }
        switch entry.kindValue {
        case .card:
            guard let c = entry.card else { return "" }
            return [c.last4.isEmpty ? nil : "•••• \(c.last4)", c.expiry.map { c.expired ? "expired \($0)" : $0 }].compactMap { $0 }.joined(separator: ", ")
        case .key: return entry.sites.first ?? ""
        case .note: return "secure note"
        case .value: return entry.value ?? entry.commands.first ?? "hidden"
        case .mac: return "for sudo"
        case .login: return entry.username ?? entry.sites.first ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            EntryIcon(kind: entry.kindValue, card: entry.card, site: entry.sites.first, app: entry.apps.first, name: entry.name, size: 28, secret: entry.secret)
                .overlay(alignment: .bottomTrailing) {
                    if let live {
                        LiveDot(color: AgentStyle.color(live.agent))
                            .offset(x: 3, y: 3)
                            .help("\(live.agent) \(live.verb)")
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.name).lineLimit(1)
                    if !entry.library, entry.kindValue != .value || entry.access == "never" { PolicyGlyph(policy: entry.access) }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let code {
                CodeText(code: code.code, size: 12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Ring(period: code.period, size: 11)
            }
        }
        .padding(.vertical, 3)
    }
}

/// An agent is using this entry right now.
struct LiveDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .background(Circle().fill(color.opacity(0.5)).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// The row a new entry occupies while it's being filled in.
private struct NewRow: View {
    @State private var ui = UIState.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("New \(ui.newKind.inSentence)")
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

/// One item per kind, for the + menu and the File menu. There's one Mac password, so once it's saved
/// that item opens it instead.
struct NewMenu: View {
    @State private var engine = Engine.shared

    var body: some View {
        ForEach(Kind.allCases) { k in
            if k == .mac, let mac = engine.entries.first(where: { $0.kindValue == .mac }) {
                Button("Mac Password", systemImage: k.symbol) { UIState.shared.go(.entry(mac.id)) }
            } else {
                Button(k == .value ? "Remember a Value…" : "New \(k.title)…", systemImage: k.symbol) { UIState.shared.startEdit(nil, kind: k) }
            }
        }
    }
}

/// Browser and agent connection at the bottom of the sidebar.
private struct StatusFooter: View {
    @State private var engine = Engine.shared

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Windows.shared.showSettings(tab: "browser")
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(engine.browsers.isEmpty ? Color.orange : .green)
                        .frame(width: 7, height: 7)
                    Text(engine.browsers.isEmpty ? "Browser not connected" : "\(engine.browsers.joined(separator: ", ")) connected")
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(engine.browsers.isEmpty ? "install the otto extension so agents can fill logins in your browser" : "agents can fill logins there")
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { Windows.shared.showSettings() }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}

/// Copy / edit / delete, shared by the sidebar's context menu and the detail pane.
struct EntryMenu: View {
    let entry: Entry
    let code: Code?

    var body: some View {
        if let code, entry.totp != nil { Button("Copy 2FA Code") { Setup.copy(code.code, clearAfter: 30) } }
        if let u = entry.username, !u.isEmpty { Button("Copy Username") { Setup.copy(u) } }
        if entry.hasPassword {
            Button("Copy Password") { Task { await EntryActions.copyPassword(entry) } }
        }
        switch entry.kindValue {
        case .card: Button("Copy Card Number") { Task { await EntryActions.copySecret(entry, "number", "the card number") } }
        case .key: Button("Copy Key") { Task { await EntryActions.copySecret(entry, "key", "the key") } }
        case .note: Button("Copy Note") { Task { await EntryActions.copySecret(entry, "notes", "the note") } }
        case .value:
            if let v = entry.value {
                Button("Copy Value") { Setup.copy(v) }
            } else {
                Button("Copy Value") { Task { await EntryActions.copySecret(entry, "value", "the value") } }
            }
        default: EmptyView()
        }
        if let s = entry.sites.first, let url = URL(string: "https://\(s)") {
            Button("Open \(s)") { NSWorkspace.shared.open(url) }
        }
        if !entry.library, entry.kindValue != .value {
            if entry.activeBypass != nil {
                Button("Turn Off Bypass") { Task { try? await Engine.shared.bypassOff(entry.id) } }
            } else {
                Button("Turn On Bypass…") { Task { await EntryActions.turnOnBypass(entry) } }
            }
        }
        Divider()
        Button("Edit") { UIState.shared.startEdit(entry) }
        Button("Delete…") { EntryActions.confirmDelete(entry) }
    }
}

@MainActor
enum EntryActions {
    static func password(_ e: Entry) async -> String? {
        guard await Auth.evaluate("copy the password for \(e.name)") else { return nil }
        return await Engine.shared.secret(e.id, "password")
    }

    static func copyPassword(_ e: Entry) async {
        if let p = await password(e) { Setup.copy(p, concealed: true, clearAfter: 45) }
    }

    /// Any other secret value, after Touch ID; `what` finishes "copy …".
    static func secret(_ e: Entry, _ field: String, _ what: String) async -> String? {
        guard await Auth.evaluate("copy \(what) for \(e.name)") else { return nil }
        return await Engine.shared.secret(e.id, field)
    }

    static func copySecret(_ e: Entry, _ field: String, _ what: String) async {
        if let v = await secret(e, field, what) { Setup.copy(v, concealed: true, clearAfter: 45) }
    }

    /// The consent window, then the service seals the yes to this entry.
    static func turnOnBypass(_ e: Entry) async {
        let consent = await Windows.shared.consentBypass(BypassRequest(entry: e))
        guard consent["granted"] as? Bool == true else { return }
        do {
            try await Engine.shared.bypassOn(e.id, consent: consent)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Bypass didn't turn on"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func confirmDelete(_ e: Entry) {
        let alert = NSAlert()
        alert.messageText = "Delete \(e.name)?"
        alert.informativeText = "agents lose access to it right away. it stays in Recently Deleted for 30 days, in case you want it back."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                try? await Engine.shared.delete(e.id)
                let ui = UIState.shared
                if ui.route == .entry(e.id) {
                    ui.doneEditing()
                    ui.route = .activity
                }
            }
        }
    }
}

struct RecoveryPrompt: View {
    let message: String
    @State private var key = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key").font(.title2).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
            Field(placeholder: "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $key, mono: true)
            Button(busy ? "Opening…" : "Open vault") {
                busy = true
                Task {
                    await Engine.shared.unlock(recoveryKey: key)
                    busy = false
                }
            }
            .buttonStyle(PrimaryButton())
            .disabled(key.count < 10 || busy)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
