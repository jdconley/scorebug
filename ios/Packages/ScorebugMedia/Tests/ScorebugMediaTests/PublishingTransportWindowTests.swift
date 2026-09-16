import XCTest
@testable import ScorebugMedia

final class PublishingTransportWindowTests: XCTestCase {
    private func sample(_ time: Double, sent: UInt64 = 1000, retrans: UInt64 = 0,
                        drops: Int32 = 0, gauge: Int32 = 0, rtt: Double? = nil,
                        generation: UInt64 = 1) -> PublishingTransportStatistics {
        .init(publishingGeneration: generation, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
              sentBytes: sent, retransmittedBytes: retrans, droppedPackets: drops,
              rttMilliseconds: rtt ?? Double(gauge), estimatedBandwidthMbps: 999,
              senderBufferedBytes: gauge, senderBufferMilliseconds: gauge, availableSenderBytes: 1000)!
    }
    func testNonuniformTimeWeightsUsePrecedingSampleAndExactCounterDeltas() throws {
        var tracker = PublishingTransportStatisticsTracker()
        let base = UInt64.max - 10000
        tracker.observe(sample(10, sent: base, retrans: base - 1000, drops: 4, gauge: 100))
        tracker.observe(sample(11, sent: base + 1000, retrans: base - 900, drops: 5, gauge: 400))
        tracker.observe(sample(13, sent: base + 4000, retrans: base - 600, drops: 8, gauge: 0))
        let w = try XCTUnwrap(tracker.snapshot.window)
        XCTAssertEqual(w.publishingGeneration, 1)
        XCTAssertEqual(w.start, 10); XCTAssertEqual(w.end, 13); XCTAssertEqual(w.sampleCount, 3)
        XCTAssertEqual(w.sentBytes, 4000); XCTAssertEqual(w.retransmittedBytes, 400)
        XCTAssertEqual(w.droppedPackets, 4)
        XCTAssertEqual(w.meanBufferedBytes, 300, accuracy: 1e-10)
        XCTAssertEqual(w.meanBufferMilliseconds, 300, accuracy: 1e-10)
        XCTAssertEqual(w.meanRTTMilliseconds, 300, accuracy: 1e-10)
        XCTAssertEqual(w.maximumBufferedBytes, 400)
        XCTAssertEqual(w.maximumBufferMilliseconds, 400)
        XCTAssertEqual(w.maximumRTTMilliseconds, 400)
    }
    func testRealEndpointsAndFiveSecondHorizon() throws {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample(0)); tracker.observe(sample(0.999))
        XCTAssertNil(tracker.snapshot.window)
        tracker.observe(sample(1))
        XCTAssertEqual(tracker.snapshot.window?.start, 0)
        for time in [2.0, 3, 4, 5] { tracker.observe(sample(time)) }
        XCTAssertEqual(tracker.snapshot.window?.start, 0)
        tracker.observe(sample(5.5))
        XCTAssertEqual(tracker.snapshot.window?.start, 0.999)
        XCTAssertEqual(tracker.snapshot.window?.end, 5.5)
        XCTAssertEqual(tracker.snapshot.window?.sampleCount, 7)
    }
    func testGapClearsCoverageAndRequiresNewBaseline() throws {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample(10)); tracker.observe(sample(12))
        XCTAssertNotNil(tracker.snapshot.window)
        tracker.observe(sample(14.001))
        XCTAssertNil(tracker.snapshot.window)
        tracker.observe(sample(14.5))
        XCTAssertNil(tracker.snapshot.window)
        tracker.observe(sample(15.5))
        XCTAssertEqual(tracker.snapshot.window?.start, 14.001)
        XCTAssertEqual(tracker.snapshot.window?.sampleCount, 3)
    }
    func testRingEvictionNeverInventsEvictedCoverage() throws {
        var tracker = PublishingTransportStatisticsTracker()
        for i in 0...1000 { tracker.observe(sample(Double(i) / 1000)) }
        XCTAssertNil(tracker.snapshot.window, "Only 63ms remain in the bounded ring")
        tracker.observe(sample(2))
        let w = try XCTUnwrap(tracker.snapshot.window)
        XCTAssertEqual(w.sampleCount, 64)
        XCTAssertEqual(w.start, 0.938)
        XCTAssertEqual(w.end, 2)
    }
    func testDuplicateMissingAndQueriesCannotExtendCoverageOrRefreshLease() throws {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample(10)); let end = sample(11); tracker.observe(end)
        let snapshot = tracker.snapshot
        tracker.observe(nil); tracker.observe(end)
        XCTAssertEqual(tracker.snapshot, snapshot)
        XCTAssertNotNil(snapshot.freshWindow(at: 13))
        for now in [10, 13.0001, -.infinity, .nan, 1e12 + 1] {
            XCTAssertNil(snapshot.freshWindow(at: now))
        }
        for age in [-1.0, .nan, .infinity] {
            XCTAssertNil(snapshot.freshWindow(at: 11, maximumAge: age))
        }
    }
    func testContradictionClearsWindowsPermanentlyButKeepsScalarHistory() {
        for bad in [sample(12, generation: 2), sample(9), sample(11, gauge: 1), sample(12, sent: 999)] {
            var tracker = PublishingTransportStatisticsTracker()
            tracker.observe(sample(10)); tracker.observe(sample(11))
            XCTAssertNotNil(tracker.snapshot.window)
            tracker.observe(bad)
            XCTAssertTrue(tracker.snapshot.isQuarantined)
            XCTAssertNil(tracker.snapshot.window)
            XCTAssertEqual(tracker.snapshot.latest, sample(11))
            tracker.observe(sample(13))
            XCTAssertNil(tracker.snapshot.freshWindow(at: 13))
        }
    }
    func testCloseFreezesHistoricalWindowAndStopsFreshAccess() throws {
        var tracker = PublishingTransportStatisticsTracker()
        tracker.observe(sample(10)); tracker.observe(sample(11)); tracker.close()
        let closed = tracker.snapshot
        XCTAssertNotNil(closed.window)
        XCTAssertNil(closed.freshWindow(at: 11))
        tracker.observe(sample(12))
        XCTAssertEqual(tracker.snapshot, closed)
        XCTAssertNil(PublishingTransportStatisticsTracker().snapshot.window)
    }
    func testFiniteExtremeGaugesStayFiniteAndEndpointMaximaAreIncluded() throws {
        var tracker = PublishingTransportStatisticsTracker()
        for t in [0.0, 1.7, 3.5, 5] { tracker.observe(sample(t, gauge: .max, rtt: .greatestFiniteMagnitude)) }
        let w = try XCTUnwrap(tracker.snapshot.window)
        XCTAssertTrue(w.meanRTTMilliseconds.isFinite)
        XCTAssertEqual(w.meanRTTMilliseconds / Double.greatestFiniteMagnitude, 1, accuracy: 1e-15)
        XCTAssertEqual(w.meanBufferedBytes, Double(Int32.max), accuracy: 1e-6)
        var end = PublishingTransportStatisticsTracker()
        end.observe(sample(0)); end.observe(sample(1, gauge: 1000))
        XCTAssertEqual(end.snapshot.window?.meanBufferedBytes, 0)
        XCTAssertEqual(end.snapshot.window?.maximumBufferedBytes, 1000)
    }
}
