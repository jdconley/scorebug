import CryptoKit
import Foundation
import ScorebugCore
import Security

struct PendingCaptureReport: Codable {
    var credential: MatchCredential
    var report: RecordingReport
    var delivered: Bool
}
struct SavedCaptureSetup: Codable {
    var endpoint: String
    var installationToken: String
    var deviceId: String
    var workerId: String
    var outputId: String
    var credential: MatchCredential?
    var reports: [PendingCaptureReport]
    // Optional for decoding setups written before the stop-ownership ledger.
    // At most 64 IDs, reserved before issuing broadcast intent and never evicted.
    var stopRecordingIDs: [String]? = nil

    var endpointScope: String {
        var components = URLComponents(string: endpoint)!
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80) || (components.scheme == "https" && components.port == 443) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        let account = SHA256.hash(data: Data(installationToken.utf8)).map { String(format: "%02x", $0) }.joined()
        return components.string! + "#" + account
    }
}

/// Separate from scoring. Complete credential and recording-report state is
/// atomically replaced in the device-only Keychain; publishing URLs are absent.
protocol CaptureSetupStorage {
    func load() throws -> SavedCaptureSetup?
    func save(_ setup: SavedCaptureSetup) throws
}
struct CaptureKeychain: CaptureSetupStorage {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "live.scorebug.capture.setup", kSecAttrAccount as String: "native-capture"]
    func load() throws -> SavedCaptureSetup? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CaptureControlError.storage }
        return try JSONDecoder().decode(SavedCaptureSetup.self, from: data)
    }
    func save(_ setup: SavedCaptureSetup) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(setup),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CaptureControlError.storage }
    }
}

enum CaptureControlError: Error { case storage, noSetup, noActiveMatch, invalidCredential, recordingStopped, rejected, unresolved, selectionChanged }
