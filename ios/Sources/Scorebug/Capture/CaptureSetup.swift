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
    var sessionToken: String
    var deviceId: String
    var credential: MatchCredential?
    var reports: [PendingCaptureReport]
    /// The stop-ownership ledger: at most 64 IDs, reserved before issuing broadcast intent
    /// and cleared once the owned broadcast is stopped.
    var stopRecordingIDs: [String] = []
    /// The team whose match routes this setup uses.
    var teamId: String

    var endpointScope: String {
        var components = URLComponents(string: endpoint)!
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80) || (components.scheme == "https" && components.port == 443) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        let account = SHA256.hash(data: Data(sessionToken.utf8)).map { String(format: "%02x", $0) }.joined()
        return components.string! + "#" + account + "@" + teamId
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
        // A setup this build can't read is no setup: the next match connects from scratch.
        return try? JSONDecoder().decode(SavedCaptureSetup.self, from: data)
    }
    func save(_ setup: SavedCaptureSetup) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(setup),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CaptureControlError.storage }
    }
}

enum CaptureControlError: Error { case storage, noSetup, noActiveMatch, invalidCredential, recordingStopped, rejected, unresolved, selectionChanged,
    /// Go Live refusals. Nothing changed on the server, so Go Live can be tried again.
    youtubeNotSet, youtubeNeedsReconnect, youtubeLiveDisabled, youtubeUnavailable, streamUnavailable, busy, timeLimit

    init(rejection code: String?) {
        switch code {
        case "youtube_not_set": self = .youtubeNotSet
        case "youtube_needs_reconnect": self = .youtubeNeedsReconnect
        case "youtube_live_disabled": self = .youtubeLiveDisabled
        case "youtube_unavailable": self = .youtubeUnavailable
        case "stream_unavailable", "container_unavailable": self = .streamUnavailable
        case "busy": self = .busy
        case "time_limit": self = .timeLimit
        default: self = .rejected
        }
    }

    /// What the live screen says when Go Live is refused. The recording never stops for it.
    var goLiveMessage: String? {
        switch self {
        case .youtubeNotSet: "Your team has no YouTube channel yet, so this match can't go live. Recording continues."
        case .youtubeNeedsReconnect: "YouTube needs reconnecting. Ask your team owner to reconnect it. Recording continues."
        case .youtubeLiveDisabled: "This YouTube channel can't live stream yet. YouTube makes new channels wait 24 hours. Recording continues."
        case .youtubeUnavailable: "YouTube isn't answering right now. Try going live again in a minute. Recording continues."
        case .streamUnavailable: "Scorebug couldn't start the stream. Try going live again. Recording continues."
        case .busy: "Scorebug is busy, try again shortly. Recording continues."
        case .timeLimit: "This match reached the 4-hour streaming limit. Recording continues."
        default: nil
        }
    }
}
