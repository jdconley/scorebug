import CryptoKit
import Foundation
import Testing
@testable import SRTHaishinKit

@Suite struct SRTProbeStageMessageTests {
    private let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!

    @Test func independentStagedVectorAndAllPacketOrdinals() throws {
        let data = try SRTProbeMessage.encodeStage(id: id, generation: 0x0102030405060708,
            stage: 31, sequence: 0, bitRate: 1_000_000)
        // Independently specified Go reader vector uses the same bytes.
        let prefix: [UInt8] = [0x47,0x1f,0xff,0x10, 0x53,0x42,0x55,0x47,0x50,0x52,0x42,0x32,
            0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,
            1,2,3,4,5,6,7,8, 0,0,0,0,0,0,0,0, 0,0x0f,0x42,0x40]
        #expect(data.count == 1316)
        for part in 0..<7 {
            let at = part * 188
            #expect(Array(data[at..<at + 48]) == prefix)
            #expect(data[at + 48] == UInt8(part))
            #expect(Array(data[at + 49..<at + 53]) == [0,0,0,31])
            #expect(data[at + 53..<at + 188].allSatisfy { $0 == 0xff })
        }
    }

    @Test func legalBoundsAndLegacyFormatRemainIndependent() throws {
        for stage: UInt32 in [1, 32] {
            for rate in [1, 2_000_000, 2_000_001, 12_000_000] {
                let sequence = UInt64(16 * 1024 * 1024 / 1316 - 1)
                let data = try SRTProbeMessage.encodeStage(id: id, generation: UInt64.max,
                    stage: stage, sequence: sequence, bitRate: rate)
                #expect(data[11] == 0x32)
                #expect(Array(data[28..<36]) == Array(repeating: 0xff, count: 8))
                var expectedSequence = sequence.bigEndian
                withUnsafeBytes(of: &expectedSequence) { #expect(Array(data[36..<44]) == Array($0)) }
                #expect(data[52] == UInt8(stage))
            }
        }
        let legacy = SRTProbeMessage.encode(id: id, generation: 1, sequence: 0, bitRate: 1_000_000)
        for part in 0..<7 {
            let at = part * 188
            #expect(legacy[at + 11] == 0x31)
            #expect(legacy[at + 49..<at + 188].allSatisfy { $0 == 0xff })
        }
    }

    @Test(arguments: 0..<11) func invalidInputThrowsBeforeIntegerConversion(mode: Int) {
        var id = self.id, generation: UInt64 = 1, stage: UInt32 = 1, sequence: UInt64 = 0, rate = 1_000_000
        switch mode {
        case 0: id = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        case 1: generation = 0
        case 2: stage = 0
        case 3: stage = 33
        case 4: stage = .max
        case 5: rate = 0
        case 6: rate = -1
        case 7: rate = 12_000_001
        case 8: rate = .max
        case 9: sequence = UInt64(16 * 1024 * 1024 / 1316)
        default: sequence = .max
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTProbeMessage.encodeStage(id: id, generation: generation,
                stage: stage, sequence: sequence, bitRate: rate)
        }
    }
}

@Suite struct SRTProbeCampaignMessageTests {
    private let id = UUID(uuidString: "01020304-0506-4708-890a-0b0c0d0e0f10")!

    @Test func independentCampaignGoldenVectorAndAllPacketOrdinals() throws {
        let data = try SRTProbeMessage.encodeCampaign(id: id, generation: 0x0102030405060708,
            campaign: .max, stage: 31, sequence: 0, bitRate: 12_000_000)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "cf9b15b536c40fe65844f463057ac7c190cc580ef3fe45d9f4ea6f5e03a51b2a")
        if let output = ProcessInfo.processInfo.environment["SCOREBUG_CAMPAIGN_GOLDEN_PATH"] {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let prefix: [UInt8] = [0x47,0x1f,0xff,0x10, 0x53,0x42,0x55,0x47,0x50,0x52,0x42,0x33,
            1,2,3,4,5,6,0x47,8,0x89,10,11,12,13,14,15,16,
            1,2,3,4,5,6,7,8, 0,0,0,0,0,0,0,0, 0,0xb7,0x1b,0]
        #expect(data.count == 1316)
        for part in 0..<7 {
            let at = part * 188
            #expect(Array(data[at..<at + 48]) == prefix)
            #expect(data[at + 48] == UInt8(part))
            #expect(Array(data[at + 49..<at + 57]) == [0,0,0,31,255,255,255,255])
            #expect(data[at + 57..<at + 188].allSatisfy { $0 == 0xff })
        }
    }

    @Test func legalCampaignBoundsPreserveV2PrefixLayout() throws {
        for campaign: UInt32 in [1, 0x01020304, .max] {
            for stage: UInt32 in [1, 32] {
                for rate in [1, 12_000_000] {
                    let sequence = UInt64(16 * 1024 * 1024 / 1316 - 1)
                    let v2 = try SRTProbeMessage.encodeStage(id: id, generation: .max,
                        stage: stage, sequence: sequence, bitRate: rate)
                    let v3 = try SRTProbeMessage.encodeCampaign(id: id, generation: .max,
                        campaign: campaign, stage: stage, sequence: sequence, bitRate: rate)
                    for part in 0..<7 {
                        let at = part * 188
                        #expect(v3[at + 11] == 0x33)
                        #expect(v3[at..<at + 11] == v2[at..<at + 11])
                        #expect(v3[at + 12..<at + 53] == v2[at + 12..<at + 53])
                        #expect(v3[at + 53..<at + 57].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } == campaign)
                    }
                }
            }
        }
    }

    @Test(arguments: 0..<12) func invalidCampaignInputThrows(mode: Int) {
        var id = self.id, generation: UInt64 = 1, campaign: UInt32 = 1, stage: UInt32 = 1
        var sequence: UInt64 = 0, rate = 1_000_000
        switch mode {
        case 0: id = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        case 1: generation = 0
        case 2: campaign = 0
        case 3: stage = 0
        case 4: stage = 33
        case 5: stage = .max
        case 6: rate = 0
        case 7: rate = -1
        case 8: rate = 12_000_001
        case 9: rate = .max
        case 10: sequence = UInt64(16 * 1024 * 1024 / 1316)
        default: sequence = .max
        }
        #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try SRTProbeMessage.encodeCampaign(id: id, generation: generation,
                campaign: campaign, stage: stage, sequence: sequence, bitRate: rate)
        }
    }
}
