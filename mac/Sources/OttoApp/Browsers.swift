import AppKit
import SwiftUI

/// Chromium browsers otto can fill logins in. The service trusts the big ones by their signature
/// and asks the user once about any other browser signed with a Developer ID.
struct KnownBrowser: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [KnownBrowser] = [
        ("com.google.Chrome", "Google Chrome"), ("com.google.Chrome.beta", "Chrome Beta"),
        ("com.google.Chrome.dev", "Chrome Dev"), ("com.google.Chrome.canary", "Chrome Canary"),
        ("com.brave.Browser", "Brave"), ("com.brave.Browser.beta", "Brave Beta"), ("com.brave.Browser.nightly", "Brave Nightly"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("com.microsoft.edgemac.Beta", "Edge Beta"),
        ("com.microsoft.edgemac.Dev", "Edge Dev"), ("com.microsoft.edgemac.Canary", "Edge Canary"),
        ("company.thebrowser.Browser", "Arc"), ("company.thebrowser.dia", "Dia"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "Opera"), ("com.operasoftware.OperaGX", "Opera GX"), ("com.operasoftware.OperaDeveloper", "Opera Developer"),
        ("ai.perplexity.comet", "Comet"), ("com.openai.atlas", "ChatGPT Atlas"), ("net.imput.helium", "Helium"),
        ("ru.yandex.desktop.yandex-browser", "Yandex Browser"), ("com.naver.Whale", "Whale"),
    ].map { KnownBrowser(id: $0.0, name: $0.1) }

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    /// what the service calls it once connected: the app's file name ("Brave Browser")
    var appName: String? {
        url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    static var installed: [KnownBrowser] { all.filter { $0.url != nil } }

    func connected(_ names: [String]) -> Bool {
        names.contains { $0 == appName || $0 == name }
    }

    /// The extension's Chrome Web Store page, in this browser.
    func openExtensionListing() {
        guard let app = url, let page = URL(string: "https://otto.alfaoz.dev/extension") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Every Chromium browser maps chrome:// to its own pages.
    func openExtensionsPage() {
        guard let app = url, let page = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A browser otto doesn't know asked to connect (approve_browser).
struct BrowserRequest {
    var name: String
    var bundle: String
    var team: String
    var signer: String
    var path: String

    /// seconds until the service stops waiting for this window
    var expiresIn: Double?

    init(_ a: [String: Any]) {
        expiresIn = a["expires_in"] as? Double
        name = a["name"] as? String ?? "a browser"
        bundle = a["bundle"] as? String ?? ""
        team = a["team"] as? String ?? ""
        signer = a["signer"] as? String ?? ""
        path = a["path"] as? String ?? ""
    }
}

/// Handing logins to a browser is a decision the user makes once per browser, with Touch ID.
struct BrowserApprovalView: View {
    let r: BrowserRequest
    let finish: (Bool) -> Void
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: r.path))
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Let \(r.name) fill your logins?")
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("a browser otto hasn't worked with before")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    line("Signed by") { Text(r.signer).fontWeight(.medium) }
                    line("Team") { Text(r.team).font(.system(.body, design: .monospaced)) }
                    line("App") { Text(r.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Label {
                    Text("allow it only if you installed \(r.name) yourself. agents can then log in through it, on each login's own sites.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text("take it back in Settings → Browser.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Don't Allow") { finish(false) }.buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        busy = true
                        if await Auth.confirm("let \(r.name) fill your logins") != nil {
                            finish(true)
                        } else {
                            problem = "Touch ID didn't go through."
                        }
                        busy = false
                    }
                } label: {
                    Label(busy ? "Waiting…" : "Allow", systemImage: "touchid")
                }
                .buttonStyle(PrimaryButton())
                .disabled(busy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 500)
        .focusEffectDisabled()
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
