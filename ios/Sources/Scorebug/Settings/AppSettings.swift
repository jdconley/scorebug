import Foundation
import Security

/// Persisted operator settings. The control-plane URL is in UserDefaults
/// for visibility; the phone token lives in the Keychain so it survives
/// reinstalls and isn't exposed via plist scraping.
@MainActor
final class AppSettings: ObservableObject {
    @Published var controlPlaneURL: String {
        didSet { UserDefaults.standard.set(controlPlaneURL, forKey: "controlPlaneURL") }
    }

    @Published var phoneToken: String {
        didSet { Keychain.set(phoneToken, for: "phoneToken") }
    }

    init() {
        self.controlPlaneURL = UserDefaults.standard.string(forKey: "controlPlaneURL")
            ?? "https://api.scorebug.live"
        self.phoneToken = Keychain.get("phoneToken") ?? ""
    }

    var isConfigured: Bool {
        URL(string: controlPlaneURL) != nil && phoneToken.count >= 16
    }
}

enum Keychain {
    static func get(_ key: String) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "live.scorebug.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let data = value.data(using: .utf8) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "live.scorebug.app",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
