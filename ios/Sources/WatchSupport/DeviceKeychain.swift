import Foundation
import ScorebugCore
import Security

/// One native owner per service/account. A failed update leaves the prior item
/// intact; values never fall back to plaintext preferences or shared app context.
struct DeviceKeychain<Value: Codable & Sendable>: Sendable {
    let service: String
    let account: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func load() throws -> Value? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw KeychainFailure.unavailable }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    func save(_ value: Value?) throws {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure.unavailable }
            return
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw KeychainFailure.unavailable }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure.unavailable }
    }
    private enum KeychainFailure: Error { case unavailable }
}

struct WatchSetupKeychain: WatchSetupStorage {
    private let keychain = DeviceKeychain<WatchSetupRecord>(service: "live.scorebug.watch.setup", account: "watch-scorer")
    func load() throws -> WatchSetupRecord? { try keychain.load() }
    func save(_ record: WatchSetupRecord) throws { try keychain.save(record) }
}

#if os(iOS)
struct PhoneWatchRequestKeychain: PhoneWatchRequestStorage {
    private let keychain = DeviceKeychain<PhoneWatchSetupRecord>(service: "live.scorebug.phone.watch-setup", account: "paired-watch")
    func load() throws -> PhoneWatchSetupRecord? { try keychain.load() }
    func save(_ record: PhoneWatchSetupRecord) throws { try keychain.save(record) }
}
#endif
