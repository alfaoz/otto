import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a login's 2FA comes from: one of your imported codes, a QR (screen or camera), or a pasted key.
struct TwoFAPicker: View {
    /// words to rank imported codes by (site, entry name, username)
    let hints: [String]
    var agent = "the agent"
    /// "app" (authenticator), "delivered" (SMS/email code), "none"
    @Binding var kind: String
    /// a pasted or scanned secret / otpauth link
    @Binding var otp: String
    /// or an imported code's entry id
    @Binding var fromID: String?

    @State private var engine = Engine.shared
    @State private var mode: Mode = .list
    @State private var query = ""
    @State private var preview: String?
    @State private var problem: String?
    @State private var camera = false

    enum Mode: Hashable { case list, scan, paste }

    private var library: [Entry] { engine.entries.filter(\.library) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Pills(options: [("app", "Authenticator app"), ("delivered", "SMS or email"), ("none", "No 2FA")], selection: $kind,
                  symbols: ["app": "number", "delivered": "message", "none": "minus.circle"])
            switch kind {
            case "delivered":
                Label("when the site sends you a code, \(agent) will ask you for it.", systemImage: "message")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case "none":
                Label("no second step. the password is enough.", systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            default:
                HStack(spacing: 4) {
                    Pills(options: [(.list, library.isEmpty ? "My codes" : "My codes (\(library.count))"), (.scan, "Scan QR"), (.paste, "Paste key")], selection: $mode, small: true)
                        .fixedSize()
                    Spacer()
                }
                switch mode {
                case .list: list
                case .scan: scan
                case .paste: paste
                }
                status
            }
        }
        .onAppear { if library.isEmpty { mode = .scan } }
        .onChange(of: library.isEmpty) { _, empty in if empty && mode == .list { mode = .scan } }
        .onChange(of: otp) { _, v in check(v) }
        .sheet(isPresented: $camera) {
            CameraSheet(hint: "hold the site's 2FA setup QR up to the camera", found: { p in
                if p.lowercased().hasPrefix("otpauth://totp") {
                    fromID = nil
                    otp = p
                    camera = false
                }
            }, done: { camera = false })
        }
    }

    private var ranked: [Entry] {
        let words = hints.compactMap { h -> String? in
            let w = h.lowercased().split(separator: ".").first.map(String.init) ?? ""
            return w.count >= 2 ? w : nil
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func text(_ e: Entry) -> String { ([e.name, e.username ?? "", e.totp?.issuer ?? "", e.totp?.account ?? ""] + e.sites).joined(separator: " ").lowercased() }
        return library
            .filter { q.isEmpty || text($0).contains(q) }
            .sorted { a, b in
                let ma = words.contains { text(a).contains($0) }, mb = words.contains { text(b).contains($0) }
                return ma != mb ? ma : a.name.lowercased() < b.name.lowercased()
            }
    }

    @ViewBuilder private var list: some View {
        if library.isEmpty {
            HStack(spacing: 6) {
                Text("no imported codes yet.").foregroundStyle(.secondary)
                Button("Import from an authenticator app…") { Windows.shared.showImport() }.buttonStyle(.plain).underline()
            }
            .font(.callout)
        } else {
            if library.count > 6 { Field(placeholder: "search your codes", text: $query) }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(ranked) { e in
                        Button {
                            otp = ""
                            fromID = e.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: fromID == e.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(fromID == e.id ? .primary : .tertiary)
                                Text(e.totp?.issuer ?? e.name).fontWeight(.medium)
                                Text(e.totp?.account ?? e.username ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if let c = engine.codes[e.id] { CodeText(code: c.code, size: 13).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(fromID == e.id ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: min(CGFloat(ranked.count) * 29 + 4, 150))
            Button("Import more…") { Windows.shared.showImport() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scan: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task {
                        do {
                            if let p = try await QR.scanScreen().first(where: { $0.lowercased().hasPrefix("otpauth://totp") }) {
                                fromID = nil
                                otp = p
                            } else {
                                problem = "no 2FA QR code on screen. open the site's 2FA setup page first"
                            }
                        } catch { problem = error.localizedDescription }
                    }
                } label: { Label("Scan the screen", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(SoftButton())
                Button { camera = true } label: { Label("Use the camera", systemImage: "camera") }
                    .buttonStyle(SoftButton())
            }
            Text("the QR from the site's \"set up authenticator app\" step. scan it with your phone too if you want a backup.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var paste: some View {
        Field(placeholder: "secret key or otpauth:// link", text: Binding(get: { otp }, set: { fromID = nil; otp = $0 }), mono: true)
    }

    @ViewBuilder private var status: some View {
        if let id = fromID, let e = engine.entries.first(where: { $0.id == id }) {
            Label("\(e.totp?.issuer ?? e.name)\(e.totp?.account.map { ", \($0)" } ?? "")", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else if let preview, !otp.isEmpty {
            Label(preview, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    private func check(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = nil
        problem = nil
        guard !t.isEmpty else { return }
        Task {
            switch await engine.parseOTP(t) {
            case .success(let r):
                guard otp.trimmingCharacters(in: .whitespacesAndNewlines) == t else { return }
                let who = [r["issuer"] as? String, r["account"] as? String].compactMap { $0 }.joined(separator: ", ")
                preview = "\(who.isEmpty ? "valid key" : who), now \(r["code"] as? String ?? "")"
            case .failure(let e):
                problem = e.message
            }
        }
    }
}

/// Bring authenticator accounts into otto from an export file, a QR on screen, or the camera.
struct ImportView: View {
    let close: () -> Void
    @State private var engine = Engine.shared
    @State private var tokens: [[String: Any]] = []
    @State private var picked = Set<String>()
    /// logins from a password export: names only; the file goes back to the service to save them
    @State private var logins: [[String: Any]] = []
    @State private var pickedLogins = Set<Int>()
    @State private var loginText: String?
    @State private var policy = "ask"
    @State private var problem: String?
    @State private var busy = false
    @State private var camera = false
    @State private var sourceFile: URL?
    @State private var result: String?
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import logins and 2FA codes").font(.title3.weight(.semibold))
                Text("bring in the logins from your password manager and the codes from your authenticator app. codes on their own stay private until you attach one to a login.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let f = sourceFile {
                    HStack {
                        Text("the export file holds your secrets unencrypted.").font(.callout).foregroundStyle(.secondary)
                        Button("Move \(f.lastPathComponent) to Trash") {
                            try? FileManager.default.trashItem(at: f, resultingItemURL: nil)
                            sourceFile = nil
                        }
                        .buttonStyle(.plain).underline().font(.callout)
                    }
                }
                HStack { Spacer(); Button("Done", action: close).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction) }
            } else if tokens.isEmpty && logins.isEmpty {
                sources
            } else {
                picker
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding([.horizontal, .bottom], 22)
        .padding(.top, 2)
        .frame(width: 480)
        .onAppear {
            // dev aid: preview the picker with a sample export (demo vault only)
            if Engine.devHome != nil, let p = ProcessInfo.processInfo.environment["OTTO_PREVIEW_IMPORT"] { Task { await load(URL(filePath: p)) } }
        }
        .sheet(isPresented: $camera) {
            CameraSheet(hint: "Google Authenticator: ⋯ → Transfer accounts → Export, then hold each QR code up to the camera. any 2FA setup QR works too.",
                        found: { p in Task { await ingest(text: p, file: nil) } },
                        done: { camera = false })
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.secondary)
                Text("drop an export file here").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { choose() } label: { Label("Choose file…", systemImage: "doc") }.buttonStyle(SoftButton())
                    Button {
                        Task {
                            do {
                                let found = try await QR.scanScreen()
                                if found.isEmpty { problem = "no QR code on screen" } else { await ingest(text: found.joined(separator: "\n"), file: nil) }
                            } catch { problem = error.localizedDescription }
                        }
                    } label: { Label("Scan screen", systemImage: "qrcode.viewfinder") }.buttonStyle(SoftButton())
                    Button { camera = true } label: { Label("Camera", systemImage: "camera") }.buttonStyle(SoftButton())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(dropping ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { items in
                _ = items.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { Task { await load(url) } } }
                }
                return true
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("works with").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("logins: Apple Passwords, Chrome, Firefox, 1Password, Bitwarden, KeePassXC (CSV export). codes: Google Authenticator (Transfer accounts QR), 2FAS, Aegis, Ente Auth, Raivo, any otpauth:// QR or list. use an unencrypted export, and delete it after.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !logins.isEmpty {
                        section("Logins", count: logins.count, all: pickedLogins.count == newLogins.count) {
                            pickedLogins = pickedLogins.count == newLogins.count ? [] : Set(newLogins.compactMap { $0["index"] as? Int })
                        }
                        ForEach(logins.indices, id: \.self) { i in loginRow(logins[i]) }
                    }
                    if !tokens.isEmpty {
                        section("2FA codes", count: tokens.count, all: picked.count == importable.count) {
                            picked = picked.count == importable.count ? [] : Set(importable.compactMap { $0["uri"] as? String })
                        }
                        .padding(.top, logins.isEmpty ? 0 : 10)
                        ForEach(tokens.indices, id: \.self) { i in row(tokens[i]) }
                    }
                }
            }
            .frame(height: min(CGFloat(logins.count + tokens.count) * 37 + (logins.isEmpty || tokens.isEmpty ? 30 : 70), 340))
            if !logins.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Agents can use the logins").font(.callout)
                        Spacer()
                        Pills(options: Policy.options, selection: $policy, small: true, symbols: ["auto": "bolt.fill", "ask": "touchid", "never": "nosign"])
                            .fixedSize()
                    }
                    Text(Policy.help(policy)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            HStack {
                Button("Start over") { tokens = []; picked = []; logins = []; pickedLogins = []; loginText = nil; problem = nil }.buttonStyle(SoftButton())
                Spacer()
                Button(busy ? "Importing…" : "Import \(picked.count + pickedLogins.count)") { Task { await save() } }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty && pickedLogins.isEmpty || busy)
            }
        }
    }

    private func section(_ title: String, count: Int, all: Bool, toggle: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title) (\(count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(all ? "Select none" : "Select all", action: toggle).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var newLogins: [[String: Any]] { logins.filter { ($0["exists"] as? Bool) != true } }

    private func loginRow(_ l: [String: Any]) -> some View {
        let index = l["index"] as? Int ?? -1
        let exists = l["exists"] as? Bool == true
        let on = pickedLogins.contains(index)
        let site = l["site"] as? String
        return Button {
            guard !exists else { return }
            if on { pickedLogins.remove(index) } else { pickedLogins.insert(index) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: exists ? "checkmark.circle" : (on ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(exists ? AnyShapeStyle(.tertiary) : (on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                SiteIcon(site: site, name: l["name"] as? String ?? "?", size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l["name"] as? String ?? "?").fontWeight(.medium).lineLimit(1)
                    Text(exists ? "already in otto" : [l["username"] as? String, site].compactMap { $0 }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if l["has_2fa"] as? Bool == true {
                    Text("2FA").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.field, in: Capsule())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .opacity(exists ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var importable: [[String: Any]] { tokens.filter { ($0["exists"] as? Bool) != true } }

    private func row(_ t: [String: Any]) -> some View {
        let uri = t["uri"] as? String ?? ""
        let exists = t["exists"] as? Bool == true
        let on = picked.contains(uri)
        return Button {
            guard !exists else { return }
            if on { picked.remove(uri) } else { picked.insert(uri) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: exists ? "checkmark.circle" : (on ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(exists ? AnyShapeStyle(.tertiary) : (on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                SiteIcon(site: t["site"] as? String, name: (t["issuer"] as? String) ?? (t["account"] as? String) ?? "?", size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text((t["issuer"] as? String) ?? (t["account"] as? String) ?? "2FA").fontWeight(.medium)
                    Text(exists ? "already in otto" : ((t["account"] as? String) ?? (t["site"] as? String) ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                CodeText(code: t["code"] as? String ?? "", size: 13).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .opacity(exists ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "pick a password manager export (.csv), an authenticator export (.csv, .json, .txt, .2fas), or a screenshot of a QR code"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    private func load(_ url: URL) async {
        problem = nil
        guard let data = try? Data(contentsOf: url) else { problem = "couldn't read \(url.lastPathComponent)"; return }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            let found = QR.decode(png: data)
            if found.isEmpty { problem = "no QR code in that image"; return }
            await ingest(text: found.joined(separator: "\n"), file: url)
        } else {
            await ingest(text: String(decoding: data, as: UTF8.self), file: url)
        }
    }

    private func ingest(text: String, file: URL?) async {
        do {
            let r = try await engine.call("import_parse", ["text": text]) as? [String: Any]
            let new = r?["tokens"] as? [[String: Any]] ?? []
            if let found = r?["logins"] as? [[String: Any]], !found.isEmpty {
                logins = found
                loginText = text
                pickedLogins = Set(found.filter { $0["exists"] as? Bool != true }.compactMap { $0["index"] as? Int })
            }
            let known = Set(tokens.compactMap { $0["uri"] as? String })
            for t in new where !known.contains(t["uri"] as? String ?? "") {
                tokens.append(t)
                if t["exists"] as? Bool != true, let u = t["uri"] as? String { picked.insert(u) }
            }
            if file != nil { sourceFile = file }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let chosen = tokens.filter { picked.contains($0["uri"] as? String ?? "") }.map { t in
            t.filter { ["issuer", "account", "uri", "site", "username"].contains($0.key) && !($0.value is NSNull) }
        }
        var args: [String: Any] = ["tokens": chosen]
        if let loginText, !pickedLogins.isEmpty {
            args["text"] = loginText
            args["logins"] = pickedLogins.sorted()
            args["policy"] = policy
        }
        do {
            let r = try await engine.call("import_save", args) as? [String: Any]
            let codes = r?["added"] as? Int ?? 0
            let added = r?["logins_added"] as? Int ?? 0
            result = "imported " + [
                added > 0 ? "\(added) login\(added == 1 ? "" : "s")" : nil,
                codes > 0 || added == 0 ? "\(codes) code\(codes == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }.joined(separator: " and ")
            loginText = nil
            camera = false
        } catch {
            problem = error.localizedDescription
        }
    }
}
