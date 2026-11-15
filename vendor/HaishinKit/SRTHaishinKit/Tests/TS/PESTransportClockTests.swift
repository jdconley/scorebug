import CoreMedia
import Foundation
import Testing
@testable import SRTHaishinKit

@Suite struct PESTransportClockTests {
    // Independent field extraction; do not use the SDK timestamp decoder.
    private func wire(_ data: Data, at i: Int = 0) -> Int64 {
        Int64(data[i] & 14) << 29 | Int64(data[i + 1]) << 22 |
        Int64(data[i + 2] & 254) << 14 | Int64(data[i + 3]) << 7 |
        Int64(data[i + 4]) >> 1
    }

    @Test func exactProjectionPreservesLargeAbsoluteClockDifference() {
        var header = PESOptionalHeader()
        header.setTimestamp(CMTime(value: Int64.max - 1, timescale: 1),
            presentationTimeStamp: CMTime(value: Int64.max, timescale: 1), decodeTimeStamp: .invalid)
        #expect(wire(header.optionalFields) == 99_000)
    }

    @Test func presentationAndDecodeTimestampsShareOneLead() {
        var header = PESOptionalHeader()
        header.setTimestamp(CMTime(value: 10, timescale: 1),
            presentationTimeStamp: CMTime(value: 41, timescale: 4),
            decodeTimeStamp: CMTime(value: 10, timescale: 1))
        #expect(wire(header.optionalFields) == 31_500)
        #expect(wire(header.optionalFields, at: 5) == 9_000)
    }

    @Test func replacementDoesNotAppendStaleTimestampFields() {
        var header = PESOptionalHeader()
        header.setTimestamp(.zero, presentationTimeStamp: CMTime(value: 1, timescale: 1),
                            decodeTimeStamp: .invalid)
        header.setTimestamp(.zero, presentationTimeStamp: CMTime(value: 2, timescale: 1),
                            decodeTimeStamp: .zero)
        #expect(header.ptsDtsIndicator == 3)
        #expect(header.pesHeaderLength == 10)
        #expect(header.optionalFields.count == 10)
        #expect(wire(header.optionalFields) == 189_000)
    }
    @Test func failedProjectionLeavesEveryHeaderByteUnchanged() {
        var header = PESOptionalHeader()
        header.dataAlignmentIndicator = true
        do { let result = header.setTimestamp(.zero, presentationTimeStamp: CMTime(value: 1, timescale: 1),
                                    decodeTimeStamp: .zero); #expect(result) }
        let previous = header.data
        for invalid in [CMTime.indefinite, .positiveInfinity,
                        CMTime(value: -1, timescale: 1),
                        CMTime(value: Int64.max, timescale: 90_000)] {
            do { let result = !header.setTimestamp(.zero, presentationTimeStamp: .zero, decodeTimeStamp: invalid); #expect(result) }
            #expect(header.data == previous)
            do { let result = !header.setTimestamp(.zero, presentationTimeStamp: invalid, decodeTimeStamp: .invalid); #expect(result) }
            #expect(header.data == previous)
        }
    }

    @Test func removingDecodeTimeReplacesIndicatorWithoutConvertingInvalidTime() {
        var header = PESOptionalHeader()
        do { let result = header.setTimestamp(.zero, presentationTimeStamp: .zero, decodeTimeStamp: .zero); #expect(result) }
        do { let result = header.setTimestamp(.zero, presentationTimeStamp: .zero, decodeTimeStamp: .invalid); #expect(result) }
        #expect(header.ptsDtsIndicator == 2)
        #expect(header.pesHeaderLength == 5)
        #expect(header.optionalFields == Data([0x21, 0, 0x01, 0x46, 0x51]))
    }

}
