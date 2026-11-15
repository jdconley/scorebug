import Foundation
import ScorebugCore
import Security

/// The one server this phone uses. An owner token is present after setup-link
/// enrollment; a phone that only joined a match through an invite has none.
struct ServerConfig: Codable, Equatable {
    var endpoint: String
    var ownerToken: String?
    var deviceId: String
    var deviceName: String
    var isOwner: Bool { ownerToken?.isEmpty == false }
    var host: String { URL(string: endpoint)?.host ?? endpoint }
}

/// A match this phone is filming or scoring; restored after a relaunch.
struct MatchSession: Codable, Equatable {
    enum Kind: String, Codable { case filming, scoring }
    var kind: Kind
    var endpoint: String
    var credential: MatchCredential
    var recordOnly: Bool
    var layout: CourtLayout
    var startedAt: Date

    var endpointScope: String { "\(endpoint)|\(credential.deviceId)" }
}

/// Small secrets in the device-only Keychain. Tests use `MemorySecureStore`.
protocol SecureStore: AnyObject {
    func data(for key: String) throws -> Data?
    func set(_ data: Data?, for key: String) throws
}

extension SecureStore {
    func value<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        try data(for: key).map { try JSONDecoder().decode(T.self, from: $0) }
    }
    func setValue<T: Encodable>(_ value: T?, for key: String) throws {
        try set(value.map { try JSONEncoder().encode($0) }, for: key)
    }
}

enum StoreKey {
    static let server = "server"
    static let session = "session"
    static let enrollmentDeviceId = "enrollment-device"
}

struct SecureStoreError: Error, Equatable { let status: Int32 }

final class KeychainStore: SecureStore {
    private let service: String
    init(service: String = "live.scorebug.app") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func data(for key: String) throws -> Data? {
        var item: CFTypeRef?
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecureStoreError(status: status) }
        return data
    }

    func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(query(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecureStoreError(status: status) }
    }
}

final class MemorySecureStore: SecureStore {
    var values: [String: Data] = [:]
    var failWrites = false
    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data?, for key: String) throws {
        if failWrites { throw SecureStoreError(status: -1) }
        values[key] = data
    }
}

/// The last finished match, for the Home card.
struct MatchRecap: Codable, Equatable {
    struct Team: Codable, Equatable { var name: String; var shortName: String; var color: String; var sets: Int }
    var team1: Team
    var team2: Team
    var setScores: String
    var final: Bool
    var date: Date

    init(snapshot: MatchSnapshot, date: Date) {
        func team(_ slot: TeamSlot) -> Team {
            let info = snapshot.teams[slot]
            return Team(name: info.name, shortName: info.shortName, color: info.color, sets: snapshot.score.sets(slot))
        }
        team1 = team(.team1); team2 = team(.team2)
        setScores = MatchSummary.setScores(snapshot)
        // "Final" only when a team actually won; the End button can stop a match early.
        final = SetPointFlow.isDecided(snapshot)
        self.date = date
    }

    /// "CASCADE 2–1 SUMMIT"
    var title: String { "\(team1.shortName) \(team1.sets)–\(team2.sets) \(team2.shortName)" }
}

/// Non-secret preferences: the last New match sheet and the last match card.
final class AppPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func read<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func write<T: Encodable>(_ value: T?, _ key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    var lastDraft: NewMatchDraft? {
        get { read("scorebug.lastDraft") }
        set { write(newValue, "scorebug.lastDraft") }
    }
    var lastMatch: MatchRecap? {
        get { read("scorebug.lastMatch") }
        set { write(newValue, "scorebug.lastMatch") }
    }
    /// Recording ID → the match it filmed, for the Recordings list.
    var recordingMatches: [String: MatchRecap] {
        get { read("scorebug.recordingMatches") ?? [:] }
        set { write(newValue, "scorebug.recordingMatches") }
    }
}
