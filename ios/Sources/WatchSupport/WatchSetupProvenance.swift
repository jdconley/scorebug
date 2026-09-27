#if DEBUG
import Foundation

/// Nonsecret UI-test assertions only; never authorizes or changes setup.
struct WatchSetupProvenance: Codable, Equatable {
    enum Invalid: Error, CustomStringConvertible {
        case expectedMatch, metadata, pendingState, offerChanged, pairedMismatch
        var description: String {
            switch self {
            case .expectedMatch: return "A valid SCOREBUG_EXPECTED_WATCH_MATCH_ID UUID is required before launching Watch."
            case .metadata: return "Watch setup identity metadata is absent or invalid."
            case .pendingState: return "Watch setup or scoring is pending; the test will preserve it without accepting, scoring or reconciling."
            case .offerChanged: return "Watch offer no longer matches the selected match and pairing."
            case .pairedMismatch: return "Watch paired identity does not match the accepted match and pairing."
            }
        }
    }
    struct Identity: Codable, Equatable {
        let gameID: String
        let pairingID: String
        init(gameID: String, pairingID: String) throws {
            // Core allows bounded non-UUID game IDs; preserve them in diagnostics.
            guard !gameID.isEmpty, gameID.utf8.count <= 128, gameID.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }) else { throw Invalid.metadata }
            self.gameID = gameID
            self.pairingID = try WatchSetupProvenance.expectedMatch(pairingID)
        }
    }
    let offered: Identity?
    let pending: Identity?
    let paired: Identity?
    let setupPending: Bool
    let scoringPending: Bool
    let ready: Bool
    let busy: Bool

    init(offered: Identity?, pending: Identity?, paired: Identity?, setupPending: Bool, scoringPending: Bool, ready: Bool, busy: Bool) {
        self.offered = offered; self.pending = pending; self.paired = paired
        self.setupPending = setupPending; self.scoringPending = scoringPending; self.ready = ready; self.busy = busy
    }
    static func expectedMatch(_ text: String?) throws -> String {
        guard let text, text.utf8.count == 36, let id = UUID(uuidString: text),
              id.uuidString.lowercased() == text.lowercased() else { throw Invalid.expectedMatch }
        return id.uuidString.lowercased()
    }
    var encoded: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
    }
    init(encoded: String) throws {
        guard encoded.utf8.count <= 1024, let data = encoded.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { throw Invalid.metadata }
        for identity in [value.offered, value.pending, value.paired].compactMap({ $0 }) {
            guard let validated = try? Identity(gameID: identity.gameID, pairingID: identity.pairingID),
                  validated == identity else { throw Invalid.metadata }
        }
        self = value
    }
    func requireNoPending() throws {
        guard !setupPending && pending == nil && !scoringPending else { throw Invalid.pendingState }
    }
    func readyForOfferWait() throws -> Bool {
        try requireNoPending()
        return ready && !busy
    }
    func matchingOffer(expected: String) throws -> Identity? {
        try requireNoPending()
        guard ready, !busy, let offered, offered.gameID == expected else { return nil }
        return offered
    }
    func requireOffer(_ selected: Identity) throws {
        guard try matchingOffer(expected: selected.gameID) == selected else { throw Invalid.offerChanged }
    }
    func requirePaired(_ selected: Identity) throws {
        try requireNoPending()
        guard ready, !busy, paired == selected else { throw Invalid.pairedMismatch }
    }
}
#endif
