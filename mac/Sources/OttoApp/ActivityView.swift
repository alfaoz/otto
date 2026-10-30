import AppKit
import SwiftUI

/// Home: is everything connected, and what agents did with otto, newest first.
struct ActivityView: View {
    @State private var engine = Engine.shared
    @State private var ui = UIState.shared
    @State private var plugin = Setup.claudePluginInstalled
    @State private var filter = ActivityFilter()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center) {
                        Text("Activity").font(.system(size: 26, weight: .bold))
                        Spacer(minLength: 12)
                        // beside the title, so nothing below moves when it comes and goes
                        if let now = engine.live.values.max(by: { $0.ts < $1.ts }) { NowPill(activity: now) }
                    }
                    .animation(.snappy, value: engine.live.isEmpty)
                    Text("everything your agents do with otto.")
                        .foregroundStyle(.secondary)
                }
                tiles
                if !engine.activity.isEmpty { FilterBar(filter: $filter, activity: engine.activity) }
                feed
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            engine.unseen = 0
            plugin = Setup.claudePluginInstalled
        }
        .onChange(of: engine.activity.count) { engine.unseen = 0 }
    }

    // MARK: status

    private var tiles: some View {
        let logins = engine.entries.filter { !$0.library && $0.kindValue == .login }
        let usable = logins.filter { $0.access != "never" }.count
        return HStack(spacing: 10) {
            Tile(symbol: "globe", title: "Browser", ok: !engine.browsers.isEmpty,
                 status: engine.browsers.isEmpty ? "not connected" : engine.browsers.joined(separator: ", "),
                 action: engine.browsers.isEmpty ? ("set up the browser extension", { Windows.shared.showSettings(tab: "browser") }) : nil)
            Tile(symbol: "terminal", title: "Claude Code", ok: plugin,
                 status: plugin ? "plugin installed" : "no plugin yet",
                 action: plugin ? nil : ("add otto to Claude Code", { Windows.shared.showSettings(tab: "agents") }))
            Tile(symbol: "key", title: "Logins", ok: nil,
                 status: logins.isEmpty ? "import yours" : "\(usable) of \(logins.count) for agents",
                 action: logins.isEmpty ? ("import logins from your password manager", { Windows.shared.showImport() }) : nil)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: feed

    private struct Day: Identifiable {
        let id: Date
        let batches: [ActivityBatch]
    }

    private var days: [Day] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: engine.activity.filter(filter.keeps)) { cal.startOfDay(for: $0.ts) }
        return groups.keys.sorted(by: >).map { Day(id: $0, batches: ActivityBatch.of(groups[$0]!.sorted { $0.ts > $1.ts })) }
    }

    private func title(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    @ViewBuilder private var feed: some View {
        if engine.activity.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 24)).foregroundStyle(.tertiary)
                Text("nothing yet").font(.headline).foregroundStyle(.secondary)
                Text("when an agent logs in, gets a 2FA code or asks you to save a login, it shows up here.")
                    .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if days.isEmpty {
            VStack(spacing: 8) {
                Text("nothing matches").font(.headline).foregroundStyle(.secondary)
                Button("Show Everything") { filter = ActivityFilter() }.buttonStyle(SoftButton())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(days) { day in
                    Block(title(day.id)) {
                        ForEach(day.batches) { b in ActivityRow(batch: b) }
                    }
                }
            }
        }
    }
}

/// Which lines of the feed to show: by agent, entry, how it went, and words in it.
struct ActivityFilter: Equatable {
    enum Outcome: String, CaseIterable {
        case all = "Everything", through = "Went Through", refused = "Refused"
    }

    var agent: String?
    var entry: String?
    var outcome = Outcome.all
    var text = ""

    var isEmpty: Bool { self == ActivityFilter() }

    func keeps(_ a: Activity) -> Bool {
        if let agent, a.agent != agent { return false }
        if let entry, a.entry?.caseInsensitiveCompare(entry) != .orderedSame { return false }
        switch outcome {
        case .all: break
        case .through: if !a.ok { return false }
        case .refused: if !a.failed { return false }
        }
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return [a.agent, a.verb, a.entry ?? "", a.detail, a.folder ?? "", a.via ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// The row above the feed: a search field and a menu for each filter, built from what's in the feed.
private struct FilterBar: View {
    @Binding var filter: ActivityFilter
    let activity: [Activity]

    private var agents: [String] { Array(Set(activity.map(\.agent))).sorted() }
    private var entries: [String] {
        var seen = Set<String>()
        return activity.compactMap(\.entry).filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("", text: $filter.text, prompt: Text("Search activity").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                if !filter.text.isEmpty {
                    Button { filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Palette.field, in: Capsule())
            .frame(maxWidth: 220)
            pick(filter.agent ?? "All Agents", active: filter.agent != nil) {
                Button("All Agents") { filter.agent = nil }
                Divider()
                ForEach(agents, id: \.self) { a in Button(a) { filter.agent = a } }
            }
            pick(filter.entry ?? "All Entries", active: filter.entry != nil) {
                Button("All Entries") { filter.entry = nil }
                Divider()
                ForEach(entries, id: \.self) { e in Button(e) { filter.entry = e } }
            }
            pick(filter.outcome.rawValue, active: filter.outcome != .all) {
                ForEach(ActivityFilter.Outcome.allCases, id: \.self) { o in Button(o.rawValue) { filter.outcome = o } }
            }
            Spacer(minLength: 0)
            if !filter.isEmpty {
                Button("Clear") { filter = ActivityFilter() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func pick<Items: View>(_ title: String, active: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(active ? Palette.hover : Palette.field, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The same thing, several times in a row: one line of the feed, "×8".
struct ActivityBatch: Identifiable {
    /// newest first
    var items: [Activity]
    var latest: Activity { items[0] }
    /// the oldest's, so the line stays what it is when another one joins it
    var id: UUID { items[items.count - 1].id }

    /// Keeps the order. A line about turning bypass on stays alone: each is a consent of its own.
    static func of(_ list: [Activity]) -> [ActivityBatch] {
        var out: [ActivityBatch] = []
        for a in list {
            if let last = out.last, last.latest.reads(like: a) {
                out[out.count - 1].items.append(a)
            } else {
                out.append(ActivityBatch(items: [a]))
            }
        }
        return out
    }
}

private extension Activity {
    func reads(like o: Activity) -> Bool {
        sealed == nil && o.sealed == nil && agent == o.agent && via == o.via && op == o.op && entry?.lowercased() == o.entry?.lowercased()
            && ok == o.ok && pending == o.pending && detail == o.detail && command == o.command && why == o.why
            && folder == o.folder && unverified == o.unverified
    }

    /// A browser isn't an agent: otto checks those some other way, and "verified" doesn't apply.
    var aboutABrowser: Bool { op == "bridge" }
}

/// One thing an agent did (or the same thing several times): who, what, with which entry, when. Click for
/// the rest: the whole message, the command, the agent's reason, where it ran.
struct ActivityRow: View {
    let batch: ActivityBatch
    private var activity: Activity { batch.latest }
    /// on the entry's own page: the entry goes without saying, and times read "12 minutes ago"
    var onEntryPage = false
    @State private var engine = Engine.shared
    @State private var hover = false
    // dev aid: OTTO_PREVIEW_OPEN=<op> starts that kind of line open, for UI previews
    @State private var open = false

    init(batch: ActivityBatch, onEntryPage: Bool = false) {
        self.batch = batch
        self.onEntryPage = onEntryPage
        _open = State(initialValue: ProcessInfo.processInfo.environment["OTTO_PREVIEW_OPEN"]?.split(separator: ",").contains { $0 == batch.latest.op } == true)
    }

    private var entry: Entry? {
        guard let n = activity.entry else { return nil }
        return engine.entries.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    var body: some View {
        let a = activity
        let avatar: CGFloat = onEntryPage ? 22 : 28
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AgentAvatar(agent: a.agent, size: avatar, failed: a.failed)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text(a.agent).fontWeight(.semibold).foregroundStyle(AgentStyle.color(a.agent)))\(a.via.map { Text(" via \($0)").foregroundStyle(.secondary) } ?? Text(""))\(a.unverified && !a.aboutABrowser ? Text(" (unverified)").foregroundStyle(.orange) : Text("")) \(a.verb)\(batch.items.count > 1 ? Text(" ×\(batch.items.count)").foregroundStyle(.secondary).fontWeight(.medium) : Text(""))")
                    // open, the whole message is below, where it can be selected
                    if (a.entry != nil && !onEntryPage) || (!a.detail.isEmpty && !open) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let n = a.entry, !onEntryPage {
                                EntryIcon(kind: entry?.kindValue ?? .login, card: entry?.card, site: entry?.sites.first, app: entry?.apps.first, name: n, size: 15)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                                Text(entry?.name ?? n).foregroundStyle(.secondary).fixedSize()
                            }
                            if !a.detail.isEmpty, !open {
                                Text(a.detail)
                                    .padding(.leading, a.entry != nil && !onEntryPage ? 6 : 0)
                                    .foregroundStyle(a.failed ? AnyShapeStyle(.red.opacity(0.9)) : AnyShapeStyle(.tertiary))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.callout)
                    }
                    if a.op == "bypass_on" { SealMark(sealed: a.sealed == true) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Group {
                        if onEntryPage { Text(a.ts, format: .relative(presentation: .named)) } else { Text(a.ts, format: .dateTime.hour().minute()) }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .opacity(hover || open ? 1 : 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, onEntryPage ? 9 : 11)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { withAnimation(.snappy(duration: 0.22)) { open.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "hides the details" : "shows the details")
            if open {
                ActivityDetails(batch: batch, entry: onEntryPage ? nil : entry)
                    .padding(.leading, 14 + avatar + 12)
                    .padding(.trailing, 14)
                    .padding(.bottom, 13)
                    .transition(.opacity)
            }
        }
        .background(hover || open ? Palette.hover : .clear)
    }
}

/// Everything the log has on one line, for checking what really happened.
struct ActivityDetails: View {
    let batch: ActivityBatch
    private var activity: Activity { batch.latest }
    /// shown with a way to open it (nil on the entry's own page)
    let entry: Entry?

    /// Each time, when there were several: only the clock if they were all on one day.
    private var times: String {
        let oneDay = Calendar.current.isDate(batch.items[0].ts, inSameDayAs: batch.items[batch.items.count - 1].ts)
        let shown = batch.items.prefix(40).map { a in
            oneDay ? a.ts.formatted(.dateTime.hour().minute()) : a.ts.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        let more = batch.items.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? ", and \(more) more" : "")
    }

    var body: some View {
        let a = activity
        VStack(alignment: .leading, spacing: 10) {
            if !a.detail.isEmpty {
                Text(a.detailBesideCommand)
                    .foregroundStyle(a.failed ? AnyShapeStyle(.red.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let command = a.fullCommand { CommandBox(command: command) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                if let why = a.why { fact("reason", "“\(why)”") }
                fact(batch.items.count > 1 ? "last" : "when", a.ts.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().second()))
                if batch.items.count > 1 { fact("\(batch.items.count) times", times) }
                if !a.aboutABrowser && a.agent != "you" { fact("agent", agent) }
                if let f = a.folder { fact("folder", f) }
                fact("result", a.pending ? "waiting for your answer" : a.ok ? "went through" : "refused")
            }
            if let entry {
                Button("Open \(entry.name)") { UIState.shared.go(.entry(entry.id)) }
                    .buttonStyle(SoftButton())
                    .padding(.top, 2)
            }
        }
        .font(.callout)
    }

    private var agent: String {
        let a = activity
        let via = a.via.map { " via \($0)" } ?? ""
        return a.unverified ? "\(a.agent)\(via), not verified: Auto and bypass didn't apply" : "\(a.agent)\(via), verified by its signature"
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary).gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// A command line as it ran: monospaced, selectable, with a copy button.
private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Setup.copy(command)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("copy the command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Whether a "turned on bypass" line really is the user's yes: otto seals the consent with the vault
/// key, so a line written by anything else (an agent editing the log) shows up as unsealed.
private struct SealMark: View {
    let sealed: Bool

    var body: some View {
        Label(sealed ? "sealed with your vault key" : "not sealed: otto didn't write this, it allows nothing",
              systemImage: sealed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(sealed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            .help(sealed ? "you ticked the box and confirmed with Touch ID; an agent can't make this record" : "")
    }
}

/// A small status card: what it is and whether it's working. When something needs doing,
/// the whole card is the button.
private struct Tile: View {
    let symbol: String
    let title: String
    /// nil: nothing to be right or wrong about
    let ok: Bool?
    let status: String
    let action: (String, () -> Void)?
    @State private var hover = false

    var body: some View {
        Button {
            action?.1()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Palette.field, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if let ok {
                            Circle().fill(ok ? Color.green : .orange).frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                .offset(x: 1, y: -1)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hover ? .secondary : .tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(action != nil && hover ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(action != nil)
        .onHover { hover = $0 }
        .help(action?.0 ?? "")
    }
}

/// What an agent is doing this moment.
private struct NowPill: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 8) {
            LiveDot(color: AgentStyle.color(activity.agent))
            Text("\(Text(activity.agent).fontWeight(.semibold)) \(activity.verb)")
            if let e = activity.entry { Text(e).foregroundStyle(.secondary) }
            Text("now").foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AgentStyle.color(activity.agent).opacity(0.14), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
