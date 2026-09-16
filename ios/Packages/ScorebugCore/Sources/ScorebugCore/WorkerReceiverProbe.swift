import Foundation

/// Untrusted wire values for relay pre-demux read accounting. Delivery here is not
/// viewer delivery or capacity; use WorkerReceiverProbeFreshness before consuming.
public struct ReceiverProbeSnapshot: Codable, Equatable, Sendable {
    public var convention: String
    public var id: String
    public var publishingGeneration: String
    public var bitRate: Int
    public var deliveredMessages: String
    public var deliveredPayloadBytes: String
    public var nextSequence: String
    public var pendingPackets: Int
    public var observedAtNanoseconds: String
    public var firstDeliveredAtNanoseconds: String?
    public var lastDeliveredAtNanoseconds: String?
    public var invalidReason: String?

    public init(convention: String, id: String, publishingGeneration: String, bitRate: Int,
                deliveredMessages: String, deliveredPayloadBytes: String, nextSequence: String,
                pendingPackets: Int, observedAtNanoseconds: String,
                firstDeliveredAtNanoseconds: String? = nil, lastDeliveredAtNanoseconds: String? = nil,
                invalidReason: String? = nil) {
        self.convention = convention; self.id = id; self.publishingGeneration = publishingGeneration
        self.bitRate = bitRate; self.deliveredMessages = deliveredMessages
        self.deliveredPayloadBytes = deliveredPayloadBytes; self.nextSequence = nextSequence
        self.pendingPackets = pendingPackets; self.observedAtNanoseconds = observedAtNanoseconds
        self.firstDeliveredAtNanoseconds = firstDeliveredAtNanoseconds
        self.lastDeliveredAtNanoseconds = lastDeliveredAtNanoseconds; self.invalidReason = invalidReason
    }

    private enum CodingKeys: String, CodingKey {
        case convention, id, publishingGeneration, bitRate, deliveredMessages, deliveredPayloadBytes, nextSequence, pendingPackets, observedAtNanoseconds, firstDeliveredAtNanoseconds, lastDeliveredAtNanoseconds, invalidReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        convention = try container.decode(String.self, forKey: .convention)
        id = try container.decode(String.self, forKey: .id)
        publishingGeneration = try container.decode(String.self, forKey: .publishingGeneration)
        bitRate = try container.decode(Int.self, forKey: .bitRate)
        deliveredMessages = try container.decode(String.self, forKey: .deliveredMessages)
        deliveredPayloadBytes = try container.decode(String.self, forKey: .deliveredPayloadBytes)
        nextSequence = try container.decode(String.self, forKey: .nextSequence)
        pendingPackets = try container.decode(Int.self, forKey: .pendingPackets)
        observedAtNanoseconds = try container.decode(String.self, forKey: .observedAtNanoseconds)
        // The API omits absent values. Explicit null must not erase invalidity.
        firstDeliveredAtNanoseconds = container.contains(.firstDeliveredAtNanoseconds) ? try container.decode(String.self, forKey: .firstDeliveredAtNanoseconds) : nil
        lastDeliveredAtNanoseconds = container.contains(.lastDeliveredAtNanoseconds) ? try container.decode(String.self, forKey: .lastDeliveredAtNanoseconds) : nil
        invalidReason = container.contains(.invalidReason) ? try container.decode(String.self, forKey: .invalidReason) : nil
    }

    private static func integer(_ value: String, maximum: UInt64 = .max) -> UInt64? {
        guard !value.isEmpty, value.utf8.count <= 20,
              value == "0" || value.utf8.first != 48,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(value), number <= maximum else { return nil }
        return number
    }

    /// Mirrors the bounded authenticated API envelope, independently of decoding.
    var validated: (generation: UInt64, observed: UInt64, last: UInt64?)? {
        guard convention == "mpegts-null-probe-v1", invalidReason == nil,
              WorkerPublication.isCanonicalUUID(id), id != "00000000-0000-0000-0000-000000000000",
              let generation = Self.integer(publishingGeneration), generation > 0,
              (1...2_000_000).contains(bitRate), (0...6).contains(pendingPackets),
              let messages = Self.integer(deliveredMessages, maximum: 16 * 1024 * 1024 / 1316),
              let bytes = Self.integer(deliveredPayloadBytes, maximum: 16 * 1024 * 1024),
              bytes == messages * 1316, nextSequence == deliveredMessages,
              let observed = Self.integer(observedAtNanoseconds, maximum: 86_400_000_000_000) else { return nil }
        guard pendingPackets == 0 || (messages + 1) * 1316 <= 16 * 1024 * 1024 else { return nil }
        if messages == 0 {
            guard firstDeliveredAtNanoseconds == nil, lastDeliveredAtNanoseconds == nil else { return nil }
            return (generation, observed, nil)
        }
        guard let firstText = firstDeliveredAtNanoseconds, let lastText = lastDeliveredAtNanoseconds,
              let first = Self.integer(firstText, maximum: observed),
              let last = Self.integer(lastText, maximum: observed), first <= last,
              messages != 1 || first == last else { return nil }
        return (generation, observed, last)
    }
}

public struct WorkerReceiverProbe: Codable, Equatable, Sendable {
    public var snapshot: ReceiverProbeSnapshot
    /// Server-owned upper age of this snapshot, not its last delivered message.
    public var ageUpperBoundMs: Double
    public init(snapshot: ReceiverProbeSnapshot, ageUpperBoundMs: Double) {
        self.snapshot = snapshot; self.ageUpperBoundMs = ageUpperBoundMs
    }
}

/// Must come from the locally owned publishing/probe attempt, not from the report.
public struct WorkerReceiverProbeExpectation: Equatable, Sendable {
    public var gameId: String
    public var generation: Int
    public var workerId: String
    public var publishingAttemptId: String
    public var probeId: String
    public var publishingGeneration: UInt64
    public var bitRate: Int

    public init(gameId: String, generation: Int, workerId: String, publishingAttemptId: String,
                probeId: String, publishingGeneration: UInt64, bitRate: Int) {
        self.gameId = gameId; self.generation = generation; self.workerId = workerId
        self.publishingAttemptId = publishingAttemptId; self.probeId = probeId
        self.publishingGeneration = publishingGeneration; self.bitRate = bitRate
    }
}
