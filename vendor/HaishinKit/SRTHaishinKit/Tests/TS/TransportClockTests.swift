import CoreMedia
import Foundation
import Testing
@testable import SRTHaishinKit

@Suite struct TransportClockTests {
    private func time(_ value: Int64, _ scale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: scale)
    }

    @Test func exactProjectionMatchesIndependentRationalExamples() throws {
        let examples: [(CMTime, CMTime, Int64)] = [
            (time(0), time(0), 0),
            (time(1, 3), time(1, 2), 15_000),
            (time(-1, 2), time(-1, 3), 15_000),
            (time(2, 3), time(4, 3), 60_000),
            (time(0), time(1, 270_000), 0),
            (time(0), time(2, 180_000), 1),
            (time(1, 3), time(40_001, 120_000), 0),
            (time(0, Int32.max), time(Int64(Int32.max) - 1, Int32.max), 89_999),
            (time(Int64.max - 1), time(Int64.max), 90_000),
            (time(Int64.min), time(Int64.min + 1), 90_000)
        ]
        for (origin, source, expected) in examples {
            let clock = try #require(TransportClock(origin: origin))
            #expect(clock.clockReference(for: source) == UInt64(expected))
            #expect(clock.presentationTimestamp(for: source) == expected + 9_000)
        }
    }

    @Test func treatsRoundedInputAsTheSuppliedRationalValue() throws {
        let source = CMTime(value: 1, timescale: 3, flags: [.valid, .hasBeenRounded], epoch: 0)
        let clock = try #require(TransportClock(origin: .zero))
        #expect(clock.presentationTimestamp(for: source) == 39_000)
    }

    @Test func rejectsInvalidOriginsAndSources() throws {
        let bad = [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                   CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0),
                   CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)]
        let clock = try #require(TransportClock(origin: .zero))
        for value in bad {
            #expect(TransportClock(origin: value) == nil)
            #expect(clock.presentationTimestamp(for: value) == nil)
            #expect(clock.clockReference(for: value) == nil)
        }
    }

    @Test func rejectsSourceBeforeOriginWithoutWrapping() throws {
        let clock = try #require(TransportClock(origin: time(1, 3)))
        for value in [time(-1), time(0), time(1, 4)] {
            #expect(clock.presentationTimestamp(for: value) == nil)
            #expect(clock.clockReference(for: value) == nil)
        }
    }

    @Test func checksWholeDifferenceAndTickOverflow() throws {
        let negative = try #require(TransportClock(origin: time(Int64.min)))
        #expect(negative.clockReference(for: time(Int64.max)) == nil)
        let zero = try #require(TransportClock(origin: .zero))
        #expect(zero.clockReference(for: time(Int64.max, 89_999)) == nil)
        #expect(zero.presentationTimestamp(for: time(Int64.max, 89_999)) == nil)
        #expect(zero.clockReference(for: time(Int64.max, 90_000)) == UInt64(Int64.max))
        #expect(zero.presentationTimestamp(for: time(Int64.max, 90_000)) == nil)
        #expect(zero.presentationTimestamp(for: time(Int64.max - 9_000, 90_000)) == Int64.max)
    }

    @Test func retainsUnwrappedTicksAndOrigin() throws {
        let origin = time(7395, 60)
        let clock = try #require(TransportClock(origin: origin))
        let wrap: Int64 = 8_589_934_592
        let source = CMTimeAdd(origin, time(wrap, 90_000))
        #expect(clock.origin == origin)
        let actual = try #require(clock.presentationTimestamp(for: source))
        #expect(actual == wrap + 9_000)
    }
}
