import Foundation

public enum DecoderDeliveryRequest: Sendable { case full, after(DecoderDeliveryCursor) }

public struct DecoderDeliveryCursor: Equatable, Sendable {
    public let scopeID: String
    public let lastOrdinal: Int64
    public init(scopeID: String, lastOrdinal: Int64) { self.scopeID = scopeID; self.lastOrdinal = lastOrdinal }
    var isValid: Bool { WorkerPublication.isCanonicalUUID(scopeID) && (0...DecoderDeliveryPacket.maximum).contains(lastOrdinal) }
}

/// All times belong to this scope's monotonic origin, never the phone's clock.
public struct DecoderDeliveryPacket: Codable, Equatable, Sendable {
    static let maximum: Int64 = 9_007_199_254_740_991
    public struct Arrival: Codable, Equatable, Sendable {
        public var pts: Int64
        public var atMs: Double
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            pts = try c.decode(Int64.self); atMs = try c.decode(Double.self)
            guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid arrival tuple") }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer(); try c.encode(pts); try c.encode(atMs)
        }
    }
    public var formatVersion: Int
    public var scopeID: String
    public var sampledAtMs: Double
    public var coverageAtMs: Double
    public var afterOrdinal: Int64
    public var lastOrdinal: Int64
    public var arrivals: [Arrival]
    public var invalidReason: String?
    public var ended: Bool
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion, scopeID, sampledAtMs, coverageAtMs, afterOrdinal, lastOrdinal, arrivals, invalidReason, ended
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid delivery fields"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        scopeID = try c.decode(String.self, forKey: .scopeID)
        sampledAtMs = try c.decode(Double.self, forKey: .sampledAtMs)
        coverageAtMs = try c.decode(Double.self, forKey: .coverageAtMs)
        afterOrdinal = try c.decode(Int64.self, forKey: .afterOrdinal)
        lastOrdinal = try c.decode(Int64.self, forKey: .lastOrdinal)
        invalidReason = try c.decodeIfPresent(String.self, forKey: .invalidReason)
        ended = try c.decode(Bool.self, forKey: .ended)
        var rows = try c.nestedUnkeyedContainer(forKey: .arrivals); arrivals = []
        while !rows.isAtEnd {
            guard arrivals.count < 256 else { throw DecodingError.dataCorruptedError(in: rows, debugDescription: "Unbounded delivery history") }
            arrivals.append(try rows.decode(Arrival.self))
        }
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid delivery bounds")) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion); try c.encode(scopeID, forKey: .scopeID)
        try c.encode(sampledAtMs, forKey: .sampledAtMs); try c.encode(coverageAtMs, forKey: .coverageAtMs)
        try c.encode(afterOrdinal, forKey: .afterOrdinal); try c.encode(lastOrdinal, forKey: .lastOrdinal)
        try c.encode(arrivals, forKey: .arrivals); try c.encode(invalidReason, forKey: .invalidReason); try c.encode(ended, forKey: .ended)
    }
    var retainedBase: Int64 { max(0, lastOrdinal - 256) }
    var isFull: Bool { isValid && afterOrdinal == retainedBase }
    var isValid: Bool {
        func time(_ n: Double) -> Bool { n.isFinite && n >= 0 && n <= Double(Self.maximum) }
        guard formatVersion == 1, WorkerPublication.isCanonicalUUID(scopeID),
              (0...Self.maximum).contains(afterOrdinal), (0...Self.maximum).contains(lastOrdinal),
              afterOrdinal <= lastOrdinal, afterOrdinal >= retainedBase,
              Int64(arrivals.count) == lastOrdinal - afterOrdinal,
              time(sampledAtMs), time(coverageAtMs), coverageAtMs <= sampledAtMs,
              lastOrdinal > 256 || coverageAtMs == 0,
              invalidReason == nil || DecodedVideoInvalidReason(rawValue: invalidReason!) != nil else { return false }
        var prior = coverageAtMs
        for row in arrivals {
            guard (-Self.maximum...Self.maximum).contains(row.pts), time(row.atMs), row.atMs >= prior, row.atMs <= sampledAtMs else { return false }
            prior = row.atMs
        }
        return true
    }
}
