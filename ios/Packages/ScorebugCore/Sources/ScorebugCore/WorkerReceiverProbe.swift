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
    public var stage: Int?
    public var totalDeliveredPayloadBytes: String?
    public var campaign: String?
    public var campaignDeliveredPayloadBytes: String?

    public init(convention: String, id: String, publishingGeneration: String, bitRate: Int,
                deliveredMessages: String, deliveredPayloadBytes: String, nextSequence: String,
                pendingPackets: Int, observedAtNanoseconds: String,
                firstDeliveredAtNanoseconds: String? = nil, lastDeliveredAtNanoseconds: String? = nil,
                invalidReason: String? = nil, stage: Int? = nil, totalDeliveredPayloadBytes: String? = nil,
                campaign: String? = nil, campaignDeliveredPayloadBytes: String? = nil) {
        self.convention = convention; self.id = id; self.publishingGeneration = publishingGeneration
        self.bitRate = bitRate; self.deliveredMessages = deliveredMessages
        self.deliveredPayloadBytes = deliveredPayloadBytes; self.nextSequence = nextSequence
        self.pendingPackets = pendingPackets; self.observedAtNanoseconds = observedAtNanoseconds
        self.firstDeliveredAtNanoseconds = firstDeliveredAtNanoseconds
        self.lastDeliveredAtNanoseconds = lastDeliveredAtNanoseconds; self.invalidReason = invalidReason
        self.stage = stage; self.totalDeliveredPayloadBytes = totalDeliveredPayloadBytes
        self.campaign = campaign; self.campaignDeliveredPayloadBytes = campaignDeliveredPayloadBytes
    }

    private enum CodingKeys: String, CodingKey {
        case convention, id, publishingGeneration, bitRate, deliveredMessages, deliveredPayloadBytes, nextSequence, pendingPackets, observedAtNanoseconds, firstDeliveredAtNanoseconds, lastDeliveredAtNanoseconds, invalidReason, stage, totalDeliveredPayloadBytes, campaign, campaignDeliveredPayloadBytes
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
        stage = container.contains(.stage) ? try container.decode(Int.self, forKey: .stage) : nil
        totalDeliveredPayloadBytes = container.contains(.totalDeliveredPayloadBytes) ? try container.decode(String.self, forKey: .totalDeliveredPayloadBytes) : nil
        campaign = container.contains(.campaign) ? try container.decode(String.self, forKey: .campaign) : nil
        campaignDeliveredPayloadBytes = container.contains(.campaignDeliveredPayloadBytes) ? try container.decode(String.self, forKey: .campaignDeliveredPayloadBytes) : nil
    }

    private static func integer(_ value: String, maximum: UInt64 = .max) -> UInt64? {
        guard !value.isEmpty, value.utf8.count <= 20,
              value == "0" || value.utf8.first != 48,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(value), number <= maximum else { return nil }
        return number
    }

    var maximumCampaignPayloadBytes: UInt64 {
        (convention == "mpegts-null-probe-v4" ? 64 : 16) * 1024 * 1024
    }

    /// Mirrors the bounded authenticated API envelope, independently of decoding.
    var validated: (generation: UInt64, observed: UInt64, last: UInt64?)? {
        let maximumBitRate = convention == "mpegts-null-probe-v4" ? 48_000_000 : convention == "mpegts-null-probe-v2" || convention == "mpegts-null-probe-v3" ? 12_000_000 : 2_000_000
        let campaignCap = maximumCampaignPayloadBytes
        guard invalidReason == nil,
              WorkerPublication.isCanonicalUUID(id), id != "00000000-0000-0000-0000-000000000000",
              let generation = Self.integer(publishingGeneration), generation > 0,
              (1...maximumBitRate).contains(bitRate), (0...6).contains(pendingPackets),
              let messages = Self.integer(deliveredMessages, maximum: campaignCap / 1316),
              let bytes = Self.integer(deliveredPayloadBytes, maximum: campaignCap),
              bytes == messages * 1316, nextSequence == deliveredMessages,
              let observed = Self.integer(observedAtNanoseconds, maximum: 86_400_000_000_000) else { return nil }
        let total: UInt64
        let publicationCap: UInt64
        switch convention {
        case "mpegts-null-probe-v1":
            guard stage == nil, totalDeliveredPayloadBytes == nil,
                  campaign == nil, campaignDeliveredPayloadBytes == nil else { return nil }
            total = bytes; publicationCap = campaignCap
        case "mpegts-null-probe-v2":
            guard campaign == nil, campaignDeliveredPayloadBytes == nil,
                  let stage, (1...32).contains(stage), let text = totalDeliveredPayloadBytes,
                  let cumulative = Self.integer(text, maximum: campaignCap),
                  cumulative % 1316 == 0, cumulative >= bytes else { return nil }
            total = cumulative; publicationCap = campaignCap
        case "mpegts-null-probe-v3", "mpegts-null-probe-v4":
            guard let stage, (1...32).contains(stage),
                  let campaign, let ordinal = Self.integer(campaign, maximum: UInt64(UInt32.max)), ordinal > 0,
                  let campaignDeliveredPayloadBytes,
                  let campaignBytes = Self.integer(campaignDeliveredPayloadBytes, maximum: campaignCap),
                  campaignBytes % 1316 == 0, campaignBytes >= bytes,
                  stage != 1 || campaignBytes == bytes,
                  let totalDeliveredPayloadBytes,
                  let cumulative = Self.integer(totalDeliveredPayloadBytes, maximum: ordinal * campaignCap),
                  cumulative % 1316 == 0, cumulative >= campaignBytes,
                  cumulative - campaignBytes <= (ordinal - 1) * campaignCap,
                  pendingPackets == 0 || campaignBytes + 1316 <= campaignCap else { return nil }
            total = cumulative; publicationCap = ordinal * campaignCap
        default: return nil
        }
        guard pendingPackets == 0 || total + 1316 <= publicationCap else { return nil }
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
    public var stage: Int?
    public var campaign: UInt32?

    public init(gameId: String, generation: Int, workerId: String, publishingAttemptId: String,
                probeId: String, publishingGeneration: UInt64, bitRate: Int, stage: Int? = nil, campaign: UInt32? = nil) {
        self.gameId = gameId; self.generation = generation; self.workerId = workerId
        self.publishingAttemptId = publishingAttemptId; self.probeId = probeId
        self.publishingGeneration = publishingGeneration; self.bitRate = bitRate; self.stage = stage
        self.campaign = campaign
    }
}
