import Foundation
import Security

/// The vault's key lives in the login keychain. macOS only lets otto read it without asking;
/// anything else (including `security find-generic-password` from an agent's shell) gets a prompt.
enum Keychain {
    static let service = "dev.alfaoz.otto"
    static let account = "vault-key"

    static func read() -> String? {
        // a throwaway dev vault (OTTO_HOME) never touches the real keychain item
        if Engine.devHome != nil { return ProcessInfo.processInfo.environment["OTTO_DEV_KEY"] }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String) throws {
        if Engine.devHome != nil { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "otto vault key"
        add[kSecAttrDescription as String] = "opens ~/Library/Application Support/otto/vault.kdbx"
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else {
            throw OttoError("keychain", SecCopyErrorMessageString(s, nil) as String? ?? "keychain error \(s)")
        }
    }

    /// 25 random base32 characters (125 bits) in groups of five, easy to write down.
    static func newKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 25)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 25, by: 5).map { String(chars[$0..<$0 + 5]) }.joined(separator: "-")
    }
}
