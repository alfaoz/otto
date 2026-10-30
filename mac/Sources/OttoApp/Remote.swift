import AppKit
import SwiftUI

/// Remote: agents send the user a link to save a login or approve a use from their phone, over
/// Tailscale. The service runs the page; the app sets the PIN and shows the paired devices.
struct RemoteStatus: Equatable {
    var pinSet: Bool
    /// PIN set, not locked
    var on: Bool
    /// 5 wrong PINs: off until the PIN is set again here
    var locked: Bool
    /// "running", "stopped", "missing" or "error"
    var tailscale: String
    var ip: String?
    var url: String?
    var listening: Bool
    var error: String?
    var devices: [RemoteDevice]

    init(_ j: [String: Any]) {
        pinSet = j["pin_set"] as? Bool ?? false
        on = j["on"] as? Bool ?? false
        locked = j["locked"] as? Bool ?? false
        tailscale = j["tailscale"] as? String ?? "missing"
        ip = j["ip"] as? String
        url = j["url"] as? String
        listening = j["listening"] as? Bool ?? false
        error = j["error"] as? String
        devices = (j["devices"] as? [[String: Any]] ?? []).compactMap(RemoteDevice.init)
    }
}

struct RemoteDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var os: String?
    var paired: Date?
    var seen: Date?

    init?(_ j: [String: Any]) {
        guard let id = j["id"] as? String else { return nil }
        self.id = id
        name = j["name"] as? String ?? "a device"
        os = j["os"] as? String
        paired = (j["paired"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        seen = (j["seen"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    var symbol: String {
        switch os?.lowercased() {
        case "ios": "iphone"
        case "ipados": "ipad"
        case "android": "smartphone"
        case "macos": "laptopcomputer"
        default: "desktopcomputer"
        }
    }
}

extension Engine {
    func loadRemote() async {
        if let r = try? await call("remote_status") as? [String: Any] { remote = RemoteStatus(r) }
    }

    /// The app confirmed with Touch ID first. Setting it again also ends a lockout.
    func setRemotePIN(_ pin: String) async throws {
        let r = try await call("remote_set_pin", ["pin": pin]) as? [String: Any]
        remote = r.map(RemoteStatus.init)
    }

    func remoteOff() async throws {
        let r = try await call("remote_off") as? [String: Any]
        remote = r.map(RemoteStatus.init)
    }

    func forgetDevice(_ id: String) async throws {
        let r = try await call("remote_forget", ["id": id]) as? [String: Any]
        remote = r.map(RemoteStatus.init)
    }
}

/// Settings ▸ Remote.
struct RemoteSettings: View {
    @State private var engine = Engine.shared
    @State private var settingPIN = false
    @State private var confirmOff = false
    @State private var problem: String?

    private var status: RemoteStatus? { engine.remote }

    var body: some View {
        Form {
            Section {
                tailscaleRow
            } footer: {
                Text("tell an agent you're away from the Mac, and it sends you a link to save a login or approve a use from your phone. nothing pops up here then, only a notification you can answer from. the link only opens over Tailscale, on your own devices, never on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if status?.locked == true {
                    LabeledContent {
                        Button("Set PIN Again…") { settingPIN = true }
                    } label: {
                        Label("remote is off: 5 wrong PINs", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("someone typed a wrong PIN 5 times. set the PIN again to turn remote back on.")
                    }
                } else {
                    LabeledContent {
                        Button(status?.pinSet == true ? "Change PIN…" : "Set PIN…") { settingPIN = true }
                    } label: {
                        Text("PIN")
                        Text(status?.pinSet == true ? "your phone asks for it once when you pair it, and for every approval" : "not set: remote is off")
                    }
                }
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            if let status, status.on, let url = status.url {
                Section {
                    CopyLine(text: url)
                } header: {
                    Text("Address")
                } footer: {
                    Text("links from agents start with this address. your phone needs Tailscale turned on too. you can add the address to its home screen.")
                        .foregroundStyle(.secondary)
                }
            }
            if status?.pinSet == true {
                Section {
                    if let devices = status?.devices, !devices.isEmpty {
                        ForEach(devices) { d in deviceRow(d) }
                    } else {
                        Text("no devices yet: the first time you open a link on your phone, it asks for the PIN.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Devices")
                }
                Section {
                    LabeledContent {
                        Button("Turn Off…") { confirmOff = true }
                    } label: {
                        Text("Turn off remote")
                        Text("forgets the PIN and every device")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await engine.loadRemote() }
        .sheet(isPresented: $settingPIN) {
            PINSheet(again: status?.pinSet == true) { pin in
                settingPIN = false
                guard let pin else { return }
                Task { await setPIN(pin) }
            }
        }
        .confirmationDialog("Turn off remote?", isPresented: $confirmOff) {
            Button("Turn Off", role: .destructive) {
                Task {
                    do { try await engine.remoteOff() } catch { problem = error.localizedDescription }
                }
            }
        } message: {
            Text("otto forgets the PIN and every paired device. links agents already sent stop working.")
        }
    }

    @ViewBuilder private var tailscaleRow: some View {
        let s = status
        LabeledContent {
            switch s?.tailscale {
            case "running":
                EmptyView()
            case "stopped":
                Button("Open Tailscale") { Tailscale.open() }
            case "missing":
                Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
            default:
                EmptyView()
            }
        } label: {
            Text("Tailscale")
            HStack(spacing: 6) {
                Circle().fill(dot.color).frame(width: 7, height: 7)
                Text(dot.text)
            }
        }
    }

    private var dot: (text: String, color: Color) {
        guard let s = status else { return ("checking", .secondary) }
        switch s.tailscale {
        case "running":
            if let e = s.error, s.on { return (e, .red) }
            if s.on && !s.listening { return ("connected, but otto isn't reachable yet", .orange) }
            return ("connected\(s.ip.map { ", this Mac is \($0)" } ?? "")", .green)
        case "stopped": return ("not connected: turn it on, here and on your phone", .orange)
        case "missing": return ("not installed: remote needs it on this Mac and your phone", .orange)
        default: return (s.error ?? "otto can't tell if it's running", .orange)
        }
    }

    private func deviceRow(_ d: RemoteDevice) -> some View {
        LabeledContent {
            Button("Remove") {
                Task {
                    do { try await engine.forgetDevice(d.id) } catch { problem = error.localizedDescription }
                }
            }
        } label: {
            Label {
                Text(d.name)
                Text(detail(d))
            } icon: {
                Image(systemName: d.symbol).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ d: RemoteDevice) -> String {
        var parts: [String] = []
        if let os = d.os, !os.isEmpty { parts.append(os) }
        if let p = d.paired { parts.append("paired \(p.formatted(.dateTime.month(.abbreviated).day()))") }
        if let s = d.seen { parts.append("last used \(Self.when(s))") }
        return parts.joined(separator: ", ")
    }

    private static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "today \(d.formatted(.dateTime.hour().minute()))" }
        if Calendar.current.isDateInYesterday(d) { return "yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    private func setPIN(_ pin: String) async {
        problem = nil
        guard await Auth.confirm("set the PIN for otto remote") != nil else {
            problem = "the PIN wasn't changed: Touch ID didn't go through."
            return
        }
        do { try await engine.setRemotePIN(pin) } catch { problem = error.localizedDescription }
    }
}

/// Six digits, typed twice. Too easy ones (123456, 000000) don't count.
private struct PINSheet: View {
    let again: Bool
    let done: (String?) -> Void
    @State private var pin = ""
    @State private var repeated = ""
    @FocusState private var focus: Int?

    private var problem: String? {
        guard pin.count == 6 else { return nil }
        if Self.easy(pin) { return "too easy to guess. pick another." }
        if repeated.count == 6 && repeated != pin { return "the two don't match." }
        return nil
    }

    private var ready: Bool { pin.count == 6 && repeated == pin && !Self.easy(pin) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(again ? "New PIN for remote" : "Set a PIN for remote").font(.title3.weight(.semibold))
                Text("6 digits. your phone asks for it once when you pair it, and every time you approve a use from it. 5 wrong tries turn remote off.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                digits("PIN", text: $pin).focused($focus, equals: 0)
                digits("again", text: $repeated).focused($focus, equals: 1)
            }
            Text(problem ?? " ").font(.callout).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button("Set PIN") { done(pin) }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear { focus = 0 }
        .onChange(of: pin) { _, v in
            pin = String(v.filter(\.isNumber).prefix(6))
            if pin.count == 6, repeated.isEmpty { focus = 1 }
        }
        .onChange(of: repeated) { _, v in repeated = String(v.filter(\.isNumber).prefix(6)) }
    }

    private func digits(_ placeholder: String, text: Binding<String>) -> some View {
        PINInput(placeholder: placeholder, text: text)
    }

    /// one digit repeated, or a run up or down
    static func easy(_ pin: String) -> Bool {
        let d = pin.compactMap(\.wholeNumberValue)
        guard d.count == 6 else { return false }
        let steps = Set(zip(d, d.dropFirst()).map { $1 - $0 })
        return steps.count == 1 && [0, 1, -1].contains(steps.first!)
    }
}

/// A PIN field: big digits, shown as dots.
struct PINInput: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum Tailscale {
    static func open() {
        let ids = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
        if let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(filePath: "/Applications/Tailscale.app"))
        }
    }
}
