import Foundation

public enum DecodedVideoInvalidReason: String, Codable, Equatable, Sendable, CaseIterable {
    case framing, numeric, ordinal, oversized, incomplete, callback, clock, overflow
}

/// Worker decoder/filter ingress cadence before frame capping and output encoding.
/// Distinct PTS are not image-content uniqueness or confirmation of viewer delivery.
/// Int64 wire counters and PTS also preserve large values on 32-bit watchOS targets.
public struct DecodedVideoWindow: Codable, Equatable, Sendable {
    public var sequence: Int64
    public var durationMs: Int
    /// Lower-bound age including server residence, but not worker-to-server transit.
    public var ageMs: Double
    /// Signed ticks at the fixed timebase 1/90000; null when no fresh frame was seen.
    public var firstPTS: Int64?
    public var lastPTS: Int64?
    public var freshFrames: Int64
    public var duplicateFrames: Int64
    public var reorderedFrames: Int64
    public var valid: Bool

    public init(sequence: Int64, durationMs: Int, ageMs: Double, firstPTS: Int64?, lastPTS: Int64?,
                freshFrames: Int64, duplicateFrames: Int64, reorderedFrames: Int64, valid: Bool) {
        self.sequence = sequence; self.durationMs = durationMs; self.ageMs = ageMs
        self.firstPTS = firstPTS; self.lastPTS = lastPTS; self.freshFrames = freshFrames
        self.duplicateFrames = duplicateFrames; self.reorderedFrames = reorderedFrames; self.valid = valid
    }
    private enum CodingKeys: String, CodingKey {
        case sequence, durationMs, ageMs, firstPTS, lastPTS, freshFrames, duplicateFrames, reorderedFrames, valid
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(ageMs, forKey: .ageMs)
        try container.encode(firstPTS, forKey: .firstPTS)
        try container.encode(lastPTS, forKey: .lastPTS)
        try container.encode(freshFrames, forKey: .freshFrames)
        try container.encode(duplicateFrames, forKey: .duplicateFrames)
        try container.encode(reorderedFrames, forKey: .reorderedFrames)
        try container.encode(valid, forKey: .valid)
    }
}

public struct DecodedVideoSnapshot: Codable, Equatable, Sendable {
    public var completed: DecodedVideoWindow?
    public var invalidReason: DecodedVideoInvalidReason?
    public var ended: Bool
    /// Omitted/unknown conventions cannot establish correspondence with native source PTS.
    /// Preserve future strings so otherwise usable status observations still decode.
    public var clock: String?
    /// Convention recognition alone does not prove freshness, matching source intervals or receipt.
    public var usesTransportClock: Bool { clock == "mpegts-pts-90k-v1" }
    public init(completed: DecodedVideoWindow?, invalidReason: DecodedVideoInvalidReason?, ended: Bool, clock: String? = nil) {
        self.completed = completed; self.invalidReason = invalidReason; self.ended = ended
        self.clock = clock
    }
    private enum CodingKeys: String, CodingKey { case completed, invalidReason, ended, clock }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(completed, forKey: .completed)
        try container.encode(invalidReason, forKey: .invalidReason)
        try container.encode(ended, forKey: .ended)
        try container.encodeIfPresent(clock, forKey: .clock)
    }
}
