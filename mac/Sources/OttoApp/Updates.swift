import Sparkle
import SwiftUI

/// Updates through Sparkle, from the appcast on otto.alfaoz.dev. An update has to pass three checks before
/// it's installed: the feed itself is signed with otto's EdDSA key (SURequireSignedFeed), the download is
/// signed with it too (checked before it's unpacked), and the app inside carries the same Developer ID as
/// this one. The public key is in Info.plist; the private one stays in the keychain of the Mac that builds
/// releases. Only release builds have a feed: a dev build never replaces itself.
@MainActor
final class Updates {
    static let shared = Updates()

    let controller: SPUStandardUpdaterController
    var updater: SPUUpdater { controller.updater }
    /// this build has a feed to check
    let enabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func check() {
        guard enabled else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return b == v ? v : "\(v) (\(b))"
    }
}

/// Settings → General: which version this is, and whether it looks for new ones by itself.
struct UpdateSettings: View {
    @State private var auto = Updates.shared.updater.automaticallyChecksForUpdates
    @State private var last = Updates.shared.updater.lastUpdateCheckDate

    var body: some View {
        Section {
            if Updates.shared.enabled {
                Toggle("Check for updates automatically", isOn: $auto)
                    .onChange(of: auto) { _, v in Updates.shared.updater.automaticallyChecksForUpdates = v }
            }
            LabeledContent {
                if Updates.shared.enabled { Button("Check Now") { Updates.shared.check() } }
            } label: {
                Text("otto \(Updates.version)")
                Text(caption)
            }
        }
        .onAppear { last = Updates.shared.updater.lastUpdateCheckDate }
    }

    private var caption: String {
        guard Updates.shared.enabled else { return "a development build: it doesn't update itself" }
        let checks = "each update carries two signatures, Apple's and otto's own, and otto checks both before installing it"
        guard let last else { return checks }
        return "last checked \(last.formatted(.relative(presentation: .named))). \(checks)"
    }
}
