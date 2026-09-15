import Foundation
import Testing

@testable import SRTHaishinKit

@Suite struct TSPacketTests {
    static let dataWithMetadata: Data = .init([71, 64, 17, 16, 0, 66, 240, 37, 0, 1, 193, 0, 0, 0, 1, 255, 0, 1, 252, 128, 20, 72, 18, 1, 6, 70, 70, 109, 112, 101, 103, 9, 83, 101, 114, 118, 105, 99, 101, 48, 49, 167, 121, 160, 3, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255])

    @Test func packet() {
        let packetWithMetadata = TSPacket(data: TSPacketTests.dataWithMetadata)!
        #expect(packetWithMetadata.syncByte == TSPacket.defaultSyncByte)
        #expect(packetWithMetadata.pid == 17)
        #expect(packetWithMetadata.data == TSPacketTests.dataWithMetadata)
    }

    @Test func programClockReference() {
        let data = Data([0, 1, 66, 68, 126, 0])
        let (b, e) = TSProgramClockReference.decode(data)
        #expect(data == TSProgramClockReference.encode(b, e))
    }

    @Test func timestamp() {
        #expect(0 == TSTimestamp.decode(Data([49, 0, 1, 0, 1])))
        #expect(0 == TSTimestamp.decode(Data([17, 0, 1, 0, 1])))
        #expect(Data([49, 0, 1, 0, 1]) == TSTimestamp.encode(0, TSTimestamp.ptsDtsMask))
        #expect(Data([17, 0, 1, 0, 1]) == TSTimestamp.encode(0, TSTimestamp.ptsMask))
    }

    @Test func timestampDecodesLiteralWireValues() {
        let fixtures: [(wire: [UInt8], ticks: Int64)] = [
            ([0x21, 0x00, 0x01, 0x00, 0x03], 1),
            ([0x21, 0x00, 0x01, 0x00, 0xff], 127),
            ([0x21, 0x00, 0x01, 0x01, 0x01], 128),
            ([0x21, 0x00, 0x07, 0xd8, 0x61], 126_000),
            ([0x29, 0x8d, 0x15, 0xcf, 0x13], 0x1_2345_6789),
            ([0x2f, 0xff, 0xff, 0xff, 0xff], 0x1_ffff_ffff)
        ]
        for fixture in fixtures {
            #expect(TSTimestamp.decode(Data(fixture.wire)) == fixture.ticks)
        }
    }

    @Test func timestampDecodesEveryLowSevenBitPattern() {
        // The final byte carries exactly seven clock bits, followed by a marker bit.
        for lowBits in UInt8(0)...UInt8(127) {
            let wire = Data([0x21, 0x00, 0x01, 0x00, lowBits * 2 + 1])
            #expect(TSTimestamp.decode(wire) == Int64(lowBits))
        }
    }

    @Test func timestampDecodesAtNonzeroOffset() {
        let wire = Data([0xaa, 0xbb, 0xcc, 0x21, 0x00, 0x07, 0xd8, 0x61, 0xdd])
        #expect(TSTimestamp.decode(wire, offset: 3) == 126_000)
    }

    @Test func timestampEncodesLiteralWireValuesModulo33Bits() {
        // Literal field bytes are independent of decode; signed inputs wrap modulo 2^33.
        let fixtures: [(ticks: Int64, fields: [UInt8])] = [
            (0, [0x01, 0x00, 0x01, 0x00, 0x01]),
            (1, [0x01, 0x00, 0x01, 0x00, 0x03]),
            (127, [0x01, 0x00, 0x01, 0x00, 0xff]),
            (128, [0x01, 0x00, 0x01, 0x01, 0x01]),
            (126_000, [0x01, 0x00, 0x07, 0xd8, 0x61]),
            (0x1_2345_6789, [0x09, 0x8d, 0x15, 0xcf, 0x13]),
            (0x1_ffff_ffff, [0x0f, 0xff, 0xff, 0xff, 0xff]),
            (0x2_0000_0000, [0x01, 0x00, 0x01, 0x00, 0x01]),
            (0x2_0000_0001, [0x01, 0x00, 0x01, 0x00, 0x03]),
            (0x3_2345_6789, [0x09, 0x8d, 0x15, 0xcf, 0x13]),
            (Int64.max, [0x0f, 0xff, 0xff, 0xff, 0xff]),
            (-1, [0x0f, 0xff, 0xff, 0xff, 0xff]),
            (-128, [0x0f, 0xff, 0xff, 0xff, 0x01]),
            (-0x2_0000_0000, [0x01, 0x00, 0x01, 0x00, 0x01]),
            (Int64.min, [0x01, 0x00, 0x01, 0x00, 0x01])
        ]
        for prefix: UInt8 in [0x10, 0x20, 0x30] {
            for fixture in fixtures {
                var expected = Data(fixture.fields)
                expected[0] |= prefix
                let encoded = TSTimestamp.encode(fixture.ticks, prefix)
                #expect(encoded == expected)
                #expect(encoded[0] & 0xf0 == prefix)
                #expect(encoded[0] & 0x01 == 0x01)
                #expect(encoded[2] & 0x01 == 0x01)
                #expect(encoded[4] & 0x01 == 0x01)
            }
        }
    }
}
