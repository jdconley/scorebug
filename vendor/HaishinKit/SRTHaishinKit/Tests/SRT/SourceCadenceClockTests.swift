import CoreMedia
import Testing
@testable import SRTHaishinKit

@Suite struct SourceCadenceClockTests {
    @Test func followsSourceCadenceAcrossBatchesAndDoesNotDelayLateFrames() throws {
        var clock = SourceCadenceClock()
        #expect(try clock.delay(sourcePTS: CMTime(value: 123250, timescale: 1000), now: 10) == 0)
        #expect(abs(try clock.delay(sourcePTS: CMTime(value: 37075, timescale: 300), now: 10.01) - (1.0 / 3 - 0.01)) < 1e-9)
        #expect(try clock.delay(sourcePTS: CMTime(value: 123750, timescale: 1000), now: 11) == 0)
        #expect(abs(try clock.delay(sourcePTS: CMTime(value: 124000, timescale: 1000), now: 11.01)) < 1e-9)
    }
    @Test func exactSubtractionPreservesSmallDeltasAtLargeSourceTimes() throws {
        var clock = SourceCadenceClock()
        let first = CMTime(value: 9_000_000_000_000_000, timescale: 30)
        #expect(try clock.delay(sourcePTS: first, now: 1) == 0)
        #expect(abs(try clock.delay(sourcePTS: CMTime(value: first.value + 1, timescale: 30), now: 1) - 1.0 / 30) < 1e-9)
    }
    @Test func rejectsInvalidReversedAndExcessivelyEarlyObservations() throws {
        for bad in [CMTime.invalid, .positiveInfinity, CMTime(value: 0, timescale: 1), CMTime(value: -1, timescale: 1), CMTime(value: 2, timescale: 1)] {
            var clock = SourceCadenceClock()
            _ = try clock.delay(sourcePTS: .zero, now: 10)
            #expect(throws: SourceCadenceClock.Failure.self) { try clock.delay(sourcePTS: bad, now: 10) }
        }
        for now in [Double.nan, .infinity, -1, 9] {
            var clock = SourceCadenceClock()
            _ = try clock.delay(sourcePTS: .zero, now: 10)
            #expect(throws: SourceCadenceClock.Failure.self) { try clock.delay(sourcePTS: CMTime(value: 1, timescale: 30), now: now) }
        }
        var changedEpoch = SourceCadenceClock()
        _ = try changedEpoch.delay(sourcePTS: .zero, now: 10)
        #expect(throws: SourceCadenceClock.Failure.self) { try changedEpoch.delay(sourcePTS: CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1), now: 10) }
    }
    @Test func newClockDoesNotCarryAnEarlierPublicationAnchor() throws {
        var first = SourceCadenceClock()
        _ = try first.delay(sourcePTS: .zero, now: 10)
        var next = SourceCadenceClock()
        #expect(try next.delay(sourcePTS: CMTime(value: 500, timescale: 1), now: 15) == 0)
    }
}
