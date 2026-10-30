import SwiftUI

@main
struct OttoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.menuBarKey) private var showMenuBar = true

    var body: some Scene {
        Window("otto", id: "main") {
            MainView()
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.check() }.disabled(!Updates.shared.enabled)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Login…") { UIState.shared.startEdit(nil) }.keyboardShortcut("n")
                ForEach(Kind.allCases.filter { $0 != .login && $0 != .mac }) { k in
                    Button("New \(k.title)…") { UIState.shared.startEdit(nil, kind: k) }
                }
                Button("Import Logins and 2FA Codes…") { Windows.shared.showImport() }.keyboardShortcut("i")
            }
            CommandGroup(after: .sidebar) {
                Button("Activity") { UIState.shared.go(.activity) }.keyboardShortcut("0")
            }
        }
        Settings {
            SettingsView()
        }
        // the setting alone decides: SwiftUI writes `true` back into this binding right after it's turned
        // off (macOS 26), which put the icon back and flipped the toggle in Settings on again
        MenuBarExtra(isInserted: Binding(get: { showMenuBar }, set: { _ in })) {
            MenuBarPanel()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
