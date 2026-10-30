import AppKit
import SwiftUI

/// Recently Deleted: entries stay a month, then the service lets them go. Agents can't see any of them.
struct TrashView: View {
    @State private var engine = Engine.shared
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recently Deleted").font(.system(size: 26, weight: .bold))
                        Text("deleted entries stay here for 30 days, out of agents' reach, then go for good.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if !engine.trash.isEmpty {
                        Button("Empty Trash…") { confirmEmpty() }.buttonStyle(SoftButton())
                    }
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
                if engine.trash.isEmpty {
                    Placeholder(symbol: "trash", title: "nothing here", detail: "entries you delete wait here for a month.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    Block("\(engine.trash.count) deleted") {
                        ForEach(engine.trash) { t in row(t) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ t: Trashed) -> some View {
        let e = t.entry
        return HStack(spacing: 12) {
            EntryIcon(kind: e.kindValue, card: e.card, site: e.sites.first, app: e.apps.first, name: e.name, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1)
                Text(when(t)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Restore") { act { try await engine.restore(t.id) } }
                .buttonStyle(SoftButton())
            Button {
                confirmPurge(t)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("delete it for good now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func when(_ t: Trashed) -> String {
        guard let d = t.deleted, let goes = t.goes else { return "deleted" }
        let ago = d.formatted(.relative(presentation: .named))
        let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: goes).day ?? 0)
        return "deleted \(ago), goes \(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")"
    }

    private func act(_ f: @escaping () async throws -> Void) {
        Task {
            do {
                try await f()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await engine.refresh()
        }
    }

    private func confirmPurge(_ t: Trashed) {
        let alert = NSAlert()
        alert.messageText = "Delete \(t.entry.name) for good?"
        alert.informativeText = "it leaves the vault now. otto's backups still have it for a while (Settings → Vault)."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { act { try await engine.purge(t.id) } }
    }

    private func confirmEmpty() {
        let alert = NSAlert()
        alert.messageText = "Empty the trash?"
        alert.informativeText = "\(engine.trash.count == 1 ? "1 entry leaves" : "\(engine.trash.count) entries leave") the vault now. otto's backups still have them for a while (Settings → Vault)."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { act { try await engine.emptyTrash() } }
    }
}

/// Settings → Vault: the copies otto keeps, and putting one back.
struct BackupsSection: View {
    @State private var engine = Engine.shared
    @State private var backups: [Backup] = []
    @State private var problem: String?

    var body: some View {
        Section {
            if backups.isEmpty {
                Text("none yet: otto makes the first one the next time something changes.").foregroundStyle(.secondary)
            } else {
                ForEach(backups.prefix(8)) { b in
                    LabeledContent {
                        Button("Restore…") { confirm(b) }
                    } label: {
                        Text(b.at.formatted(date: .abbreviated, time: .shortened))
                        Text(b.name.contains("before-restore") ? "the vault before a restore" : ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file))
                    }
                }
                if backups.count > 8 {
                    Button("Show All \(backups.count) in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Engine.supportDir.appending(path: "backups")])
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Backups")
        } footer: {
            Text("otto copies the vault before it changes it: every hour for the last 2 days, then one a day for 2 months. they open with the same recovery key.")
                .foregroundStyle(.secondary)
        }
        .task { backups = await engine.backups() }
    }

    private func confirm(_ b: Backup) {
        let alert = NSAlert()
        alert.messageText = "Go back to the vault from \(b.at.formatted(date: .abbreviated, time: .shortened))?"
        alert.informativeText = "everything changed since then is undone. the vault as it is now is kept as a backup first, so you can come back to it."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await engine.restoreBackup(b.name)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await engine.refresh()
            backups = await engine.backups()
        }
    }
}
