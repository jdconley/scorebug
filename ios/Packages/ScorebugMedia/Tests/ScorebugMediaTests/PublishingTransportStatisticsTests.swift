import XCTest
@testable import ScorebugMedia

final class PublishingTransportStatisticsTests: XCTestCase {
    private func sample(generation: UInt64 = 1, time: Double = 10, elapsed: Int64 = 1000,
                        sent: UInt64 = 10000, retrans: UInt64 = 100, drops: Int32 = 0,
                        rtt: Double = 10, bandwidth: Double = 100, buffered: Int32 = 50,
                        bufferMS: Int32 = 1, available: Int32 = 1000, delay: Int32? = nil, maximum: Double? = nil, period: Double? = nil) -> PublishingTransportStatistics? {
        .init(publishingGeneration: generation, sampledAt: time, elapsedMilliseconds: elapsed,
              sentBytes: sent, retransmittedBytes: retrans, droppedPackets: drops,
              rttMilliseconds: rtt, estimatedBandwidthMbps: bandwidth, senderBufferedBytes: buffered,
              senderBufferMilliseconds: bufferMS, availableSenderBytes: available, senderDeliveryDelayMilliseconds: delay, senderMaximumBandwidthMbps: maximum, packetSendPeriodMicroseconds: period)
    }
    func testActualPacingDiagnosticsPreserveUnknownZeroAndValidatedValues() throws {
        XCTAssertNil(try XCTUnwrap(sample()).senderMaximumBandwidthMbps)
        XCTAssertNil(try XCTUnwrap(sample()).packetSendPeriodMicroseconds)
        let measured = try XCTUnwrap(sample(maximum: 7.5, period: 1403.7))
        XCTAssertEqual(measured.senderMaximumBandwidthMbps, 7.5)
        XCTAssertEqual(measured.packetSendPeriodMicroseconds, 1403.7)
        XCTAssertNotNil(sample(maximum: 0, period: 0))
        for bad in [-1.0, .nan, .infinity] {
            XCTAssertNil(sample(maximum: bad)); XCTAssertNil(sample(period: bad))
        }
        var tracker = PublishingTransportStatisticsTracker(); tracker.observe(measured)
        tracker.observe(measured); tracker.observe(nil)
        XCTAssertEqual(tracker.snapshot.samples, [measured]); XCTAssertNil(tracker.snapshot.freshSample(at: 12.01))
    }

    func testNegotiatedDelayPreservesUnknownZeroAndActualValueWithoutInventingFreshness() throws {
        XCTAssertNil(try XCTUnwrap(sample()).senderDeliveryDelayMilliseconds)
        XCTAssertEqual(try XCTUnwrap(sample(delay: 0)).senderDeliveryDelayMilliseconds, 0)
        XCTAssertEqual(try XCTUnwrap(sample(delay: 120)).senderDeliveryDelayMilliseconds, 120)
        XCTAssertEqual(try XCTUnwrap(sample(delay: .max)).senderDeliveryDelayMilliseconds, .max)
        XCTAssertNil(sample(delay: -1))
        var tracker = PublishingTransportStatisticsTracker()
        let measured = try XCTUnwrap(sample(delay: 120))
        tracker.observe(measured); tracker.observe(nil); tracker.observe(measured)
        XCTAssertEqual(tracker.snapshot.samples.count, 1)
        XCTAssertEqual(tracker.snapshot.samples.first?.senderDeliveryDelayMilliseconds, 120)
        XCTAssertNil(tracker.snapshot.freshSample(at: 12.01))
        let historical = tracker.snapshot
        tracker.close()
        tracker.observe(sample(time: 11, delay: 500))
        XCTAssertEqual(tracker.snapshot.samples, historical.samples)
    }

    func testRejectsMalformedStatisticsAndAcceptsExactCounterExtremes() throws {
        for bad in [sample(generation: 0), sample(time: .nan), sample(time: .infinity), sample(time: -1),
                    sample(time: 1e12 + 1), sample(elapsed: -1), sample(retrans: 10001), sample(drops: -1),
                    sample(rtt: -.infinity), sample(rtt: -1), sample(bandwidth: .nan), sample(bandwidth: -1),
                    sample(buffered: -1), sample(bufferMS: -1), sample(available: -1)] { XCTAssertNil(bad) }
        XCTAssertNotNil(sample(sent: .max, retrans: .max, drops: .max))
        XCTAssertNotNil(sample(time: 0, elapsed: 0, sent: 0, retrans: 0, rtt: 0, bandwidth: 0, buffered: 0, bufferMS: 0, available: 0))
    }
    func testFreshnessUsesOriginalSamplingTimeAndMissingDuplicateReadsCannotRefreshIt() throws {
        var tracker = PublishingTransportStatisticsTracker()
        let first = try XCTUnwrap(sample())
        tracker.observe(first); tracker.observe(nil); tracker.observe(first)
        XCTAssertEqual(tracker.snapshot.latest, first)
        XCTAssertEqual(tracker.snapshot.freshSample(at: 12), first)
        for now in [9, 12.001, .nan, .infinity, -1] { XCTAssertNil(tracker.snapshot.freshSample(at: now)) }
        for age in [-1.0, .nan, .infinity] { XCTAssertNil(tracker.snapshot.freshSample(at: 10, maximumAge: age)) }
    }
    func testAcceptsAdvancingCountersAndChangingInstantaneousPressure() throws {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample())
        let next = try XCTUnwrap(sample(time: 11, elapsed: 2000, sent: 12000, retrans: 200, drops: 1,
                                        rtt: 30, bandwidth: 70, buffered: 900, bufferMS: 800, available: 10))
        tracker.observe(next)
        XCTAssertEqual(tracker.snapshot.latest, next)
        XCTAssertFalse(tracker.snapshot.isQuarantined)
    }
    func testCounterResetGenerationChangeClockReversalAndContradictionQuarantinePermanently() {
        let mutations = [sample(generation: 2, time: 11), sample(time: 9), sample(time: 11, elapsed: 999),
            sample(time: 11, sent: 9999), sample(time: 11, retrans: 99), sample(time: 11, sent: 10001, retrans: 102),
            sample(time: 10, buffered: 51)]
        for changed in mutations {
            var tracker = PublishingTransportStatisticsTracker()
            tracker.observe(sample()); tracker.observe(changed)
            XCTAssertTrue(tracker.snapshot.isQuarantined)
            XCTAssertNil(tracker.snapshot.freshSample(at: 11))
            tracker.observe(sample(time: 12, elapsed: 3000, sent: 15000))
            XCTAssertTrue(tracker.snapshot.isQuarantined)
            XCTAssertEqual(tracker.snapshot.latest, sample(), "Keep only the last consistent historical sample")
        }
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample(drops: 2)); tracker.observe(sample(time: 11, drops: 1))
        XCTAssertTrue(tracker.snapshot.isQuarantined)
    }
    func testCloseFreezesHistoryAndFreshTrackerDoesNotInheritIt() {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample()); tracker.close()
        let closed = tracker.snapshot
        tracker.observe(sample(time: 11, elapsed: 2000)); tracker.close()
        XCTAssertEqual(tracker.snapshot, closed)
        XCTAssertTrue(closed.isClosed)
        XCTAssertNil(closed.freshSample(at: 10))
        XCTAssertEqual(closed.latest, sample())
        XCTAssertNil(PublishingTransportStatisticsTracker().snapshot.latest)
    }
}
