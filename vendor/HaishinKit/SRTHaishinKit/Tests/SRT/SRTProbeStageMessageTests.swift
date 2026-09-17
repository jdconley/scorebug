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
