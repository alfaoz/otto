import AppKit
import OpenDirectory
import SwiftUI

/// This Mac's login password, checked by the system without storing anything.
enum MacAccount {
    static func check(_ password: String) async -> Bool {
        await Task.detached {
            guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
                  let user = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            else { return false }
            return (try? user.verifyPassword(password)) != nil
        }.value
    }
}

/// `otto sudo` ran before otto had the Mac password (mac_password).
struct MacPasswordRequest {
    var agent: String
    var command: String

    /// seconds until the service stops waiting for this window
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        expiresIn = a["expires_in"] as? Double
        agent = a["agent"] as? String ?? "an agent"
        command = a["command"] as? String ?? ""
    }
}

/// Enter the Mac password once, right where sudo needs it. Typing it here, with the command in view,
/// is the yes for this run; after that every sudo asks for Touch ID.
struct MacPasswordRequestView: View {
    let r: MacPasswordRequest
    /// nil: not now
    let finish: (String?) -> Void

    @State private var password = ""
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                KindGlyph(kind: .mac, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Text(r.agent).foregroundStyle(AgentStyle.color(r.agent))) wants to run a command as root")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("otto doesn't have your Mac password yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Text(r.command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                SecureField("the password you log into this Mac with", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focus)
                    .onSubmit { Task { await save() } }
                Text("otto keeps it in your vault. agents never see it, and each sudo after this one asks for your Touch ID.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Spacer()
                Button("Not Now") { finish(nil) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    Text(busy ? "Checking…" : "Save and Run")
                }
                .buttonStyle(PrimaryButton())
                .disabled(password.isEmpty || busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 500)
        .focusEffectDisabled()
        .onAppear { focus = true }
    }

    private func save() async {
        guard !password.isEmpty, !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        guard await MacAccount.check(password) else {
            problem = "that isn't this Mac's password."
            return
        }
        finish(password)
    }
}
