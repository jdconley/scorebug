import Foundation

/// Identity and ingress clock coordinates only; this does not establish freshness,
/// delivery, loss rate, or available capacity.
public struct WorkerPublication: Codable, Equatable, Sendable {
    public var readerId: String
    public var publisherId: String
    public var publishingAttemptId: String
    public var clock: WorkerPublicationClock

    public init(readerId: String, publisherId: String, publishingAttemptId: String, clock: WorkerPublicationClock) {
        self.readerId = readerId
        self.publisherId = publisherId
        self.publishingAttemptId = publishingAttemptId
        self.clock = clock
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        return value.utf8.enumerated().allSatisfy { index, byte in
            if index == 8 || index == 13 || index == 18 || index == 23 { return byte == 45 }
            return (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    var isValid: Bool {
        Self.isCanonicalUUID(readerId) && Self.isCanonicalUUID(publisherId)
            && Self.isCanonicalUUID(publishingAttemptId) && readerId != publisherId && clock.isValid
    }
}

public struct WorkerPublicationClock: Codable, Equatable, Sendable {
    public var convention: String
    /// Canonical decimal MPEG-TS PTS. Stored as a string to preserve the wire contract.
    public var originPTS: String

    public init(convention: String, originPTS: String) {
        self.convention = convention
        self.originPTS = originPTS
    }

    var isValid: Bool {
        guard convention == "mpegts-ingress-origin-90k-v1",
              !originPTS.isEmpty, originPTS.utf8.count <= 10,
              originPTS == "0" || originPTS.utf8.first != 48,
              originPTS.utf8.allSatisfy({ (48...57).contains($0) }),
              let origin = UInt64(originPTS) else { return false }
        // UInt64 avoids overflow on watchOS arm64_32.
        return origin < (UInt64(1) << 33)
    }
}

extension WorkerMediaStatus {
    private static func isPublicationScopeIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 95
        }
    }

    private static func isPublicationScopeCounter(_ value: Int) -> Bool {
        value > 0 && Int64(value) <= 9_007_199_254_740_991
    }

    /// A structurally valid association scoped to this observation. Callers must
    /// separately use WorkerStatusFreshness before treating the status as current.
    public var validatedPublication: WorkerPublication? {
        guard let publication, publication.isValid,
              let workerEpoch, WorkerPublication.isCanonicalUUID(workerEpoch),
              Self.isPublicationScopeIdentifier(gameId), Self.isPublicationScopeCounter(generation),
              let workerId, Self.isPublicationScopeIdentifier(workerId),
              state == .starting || state == .producingOutput,
              let observation, observation.gameId == gameId, observation.generation == generation,
              observation.state.rawValue == state.rawValue, Self.isPublicationScopeCounter(observation.attempt) else { return nil }
        return publication
    }
}
