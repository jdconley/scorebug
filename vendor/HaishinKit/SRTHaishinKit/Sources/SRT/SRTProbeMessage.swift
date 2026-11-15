import Foundation

/// Versioned payload in valid null TS packets. Observe before demultiplexing;
/// this identifier is attribution, not authentication or receiver capacity.
enum SRTProbeMessage {
    /// Repeatable staged probes bind every packet to a publication campaign.
    static func encodeCampaign(id: UUID, generation: UInt64, campaign: UInt32, stage: UInt32,
                               sequence: UInt64, bitRate: Int, budget: SRTBandwidthProbeBudget = .standard) throws -> Data {
        guard campaign > 0 else { throw SRTBandwidthProbeError.invalidConfiguration }
        var data = try encodeStage(id: id, generation: generation, stage: stage,
                                   sequence: sequence, bitRate: bitRate, budget: budget)
        var networkCampaign = campaign.bigEndian
        withUnsafeBytes(of: &networkCampaign) { bytes in
            for part in 0..<7 {
                let at = part * 188
                data[at + 11] = budget == .uhd ? 0x34 : 0x33 // SBUGPRB4 / SBUGPRB3
                data.replaceSubrange(at + 53..<at + 57, with: bytes)
            }
        }
        return data
    }

    /// Explicit staged probes use this version; the default legacy path retains v1.
    static func encodeStage(id: UUID, generation: UInt64, stage: UInt32,
                            sequence: UInt64, bitRate: Int) throws -> Data {
        try encodeStage(id: id, generation: generation, stage: stage, sequence: sequence,
                        bitRate: bitRate, budget: .standard)
    }

    private static func encodeStage(id: UUID, generation: UInt64, stage: UInt32,
                                    sequence: UInt64, bitRate: Int, budget: SRTBandwidthProbeBudget) throws -> Data {
        guard id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), generation > 0,
              (1...32).contains(stage), (1...budget.maximumBitRate).contains(bitRate),
              sequence < budget.maximumPayloadBytes / 1316 else {
            throw SRTBandwidthProbeError.invalidConfiguration
        }
        var data = encode(id: id, generation: generation, sequence: sequence, bitRate: bitRate)
        var networkStage = stage.bigEndian
        withUnsafeBytes(of: &networkStage) { bytes in
            for part in 0..<7 {
                let at = part * 188
                data[at + 11] = 0x32 // SBUGPRB2
                data.replaceSubrange(at + 49..<at + 53, with: bytes)
            }
        }
        return data
    }

    static func encode(id: UUID, generation: UInt64, sequence: UInt64, bitRate: Int) -> Data {
        var prefix = Array("SBUGPRB1".utf8)
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { prefix.append(contentsOf: $0) }
        for value in [generation, sequence] {
            var network = value.bigEndian
            withUnsafeBytes(of: &network) { prefix.append(contentsOf: $0) }
        }
        var rate = UInt32(bitRate).bigEndian
        withUnsafeBytes(of: &rate) { prefix.append(contentsOf: $0) }
        var bytes = [UInt8](repeating: 0xff, count: 1316)
        for part in 0..<7 {
            let at = part * 188
            bytes.replaceSubrange(at..<at + 4, with: [0x47, 0x1f, 0xff, 0x10])
            bytes.replaceSubrange(at + 4..<at + 48, with: prefix)
            bytes[at + 48] = UInt8(part)
        }
        return Data(bytes)
    }
}
