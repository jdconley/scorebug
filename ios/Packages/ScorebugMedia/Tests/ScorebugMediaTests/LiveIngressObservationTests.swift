import CoreMedia
import Foundation
import Testing
@testable import ScorebugMedia

struct LiveIngressObservationTests {
    private let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
        broadcastGeneration: 3, publishingAttemptID: UUID(), appliedProfileRevision: 7)
    private func make(history: Int = 4, limit: UInt64 = .max) throws -> LiveIngressObservationAccumulator {
        try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 10, maxItems: 4, maxBytes: 100,
            windowDuration: 5, completedWindowLimit: history, counterLimit: limit)
    }
    private func sample(_ value: Int64 = 0, kind: LiveIngressSampleKind = .video, epoch: Int64 = 0) -> LiveIngressSampleMetadata {
        LiveIngressSampleMetadata(kind: kind, sourcePTS: CMTime(value: value, timescale: 30, flags: .valid, epoch: epoch))
    }
    private func near(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.000001) }

    @Test func integratesOldDepthAndPreservesImmutableScope() throws {
        var a = try make()
        a.updateOccupancy(items: 2, bytes: 25, phase: .admitting, at: 11)
        a.updateOccupancy(items: 0, bytes: 0, at: 13)
        let s = a.poll(at: 15)
        #expect(s.scope == scope); #expect(s.monotonicAnchor == 10)
        #expect(s.maxItems == 4); #expect(s.maxBytes == 100)
        let w = try #require(s.completed.first)
        near(w.occupancy.itemSeconds, 1); near(w.occupancy.byteSeconds, 0.5)
        near(w.occupancy.maxPressureSeconds, 1); near(w.occupancy.knownDuration, 5)
        near(try #require(w.occupancy.meanMaxPressure), 0.2)
        #expect(w.occupancy.peakItems == 2); #expect(w.occupancy.peakBytes == 25)
        near(try #require(w.occupancyByPhase[.startup]).knownDuration, 1)
        near(try #require(w.occupancyByPhase[.admitting]).knownDuration, 4)
    }

    @Test func integratesInstantaneousMaximumRatherThanMaximumOfMeans() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 10, phase: .admitting, at: 10)
        a.updateOccupancy(items: 1, bytes: 100, at: 12)
        let s = a.close(at: 14)
        near(s.totalOccupancy.itemSeconds, 2.5); near(s.totalOccupancy.byteSeconds, 2.2)
        near(s.totalOccupancy.maxPressureSeconds, 4)
        near(try #require(s.totalOccupancy.meanMaxPressure), 1)
        #expect(s.phase == .closed); #expect(s.isClosed)
    }

    @Test func halfOpenBoundaryRotatesBeforeCountingAndZeroTimeHasNoArea() throws {
        var a = try make()
        a.observe(.admitted, sample: sample(1), at: 10)
        a.updateOccupancy(items: 4, bytes: 100, at: 10)
        a.observe(.dequeued, sample: sample(1), at: 10)
        a.updateOccupancy(items: 0, bytes: 0, at: 10)
        a.observe(.admitted, sample: sample(2), at: 15)
        let completed = try #require(a.snapshot.completed.first)
        #expect(completed.dispositions[.admitted]?[.video]?.count == 1)
        #expect(a.snapshot.current.dispositions[.admitted]?[.video]?.count == 1)
        near(a.snapshot.totalOccupancy.maxPressureSeconds, 0)
        #expect(a.snapshot.current.monotonicStart == 15)
        #expect(a.snapshot.current.monotonicEnd == 15)
    }

    @Test func boundaryDequeueDoesNotCarryOldPeakIntoEmptyWindowOrPhase() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 100, phase: .admitting, at: 10)
        a.updateOccupancy(items: 0, bytes: 0, phase: .draining, at: 15)
        let s = a.poll(at: 20)
        #expect(s.completed[0].occupancy.peakItems == 4)
        let empty = s.completed[1]
        near(empty.occupancy.maxPressureSeconds, 0)
        #expect(empty.occupancy.peakItems == 0)
        #expect(empty.occupancy.peakBytes == 0)
        #expect(empty.occupancyByPhase[.admitting]?.peakItems ?? 0 == 0)
        #expect(empty.occupancyByPhase[.admitting]?.peakBytes ?? 0 == 0)
        #expect(empty.occupancyByPhase[.draining]?.peakItems == 0)
        #expect(empty.occupancyByPhase[.draining]?.peakBytes == 0)
    }

    @Test func occupiedBillionSecondGapCoalescesWithFullAreaAndPhase() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 50, phase: .draining, at: 10)
        let s = a.poll(at: 1_000_000_012)
        try #require(s.completed.count == 2)
        let gap = s.completed[1]
        #expect(gap.isCoalesced); #expect(gap.coveredWindowCount == 199_999_999)
        near(gap.monotonicEnd - gap.monotonicStart, 999_999_995)
        near(gap.occupancy.itemSeconds, 999_999_995)
        near(gap.occupancy.byteSeconds, 499_999_997.5)
        near(try #require(gap.occupancyByPhase[.draining]).maxPressureSeconds, 999_999_995)
        near(s.totalOccupancy.knownDuration, 1_000_000_002)
        #expect(s.current.isPartial); #expect(s.completed.allSatisfy { !$0.isPartial })
    }

    @Test func evictionReportsUnderlyingIntervalsAndRetainsTotals() throws {
        var a = try make(history: 1)
        a.updateOccupancy(items: 4, bytes: 100, at: 10)
        a.poll(at: 40)
        #expect(a.snapshot.omittedCompletedWindowCount == 1)
        a.poll(at: 45)
        let s = a.snapshot
        #expect(s.completed.count == 1); #expect(s.omittedCompletedWindowCount == 6)
        #expect(s.omittedThroughMonotonicTime == 40)
        near(s.totalOccupancy.maxPressureSeconds, 35)
    }

    @Test func dispositionKindAndRejectionSummariesRetainRationalExtrema() throws {
        var a = try make()
        a.observe(.admitted, sample: sample(9), at: 10)
        a.observe(.admitted, sample: sample(3), at: 11)
        a.observe(.overflowEvicted, sample: sample(9), at: 11)
        a.observe(.cancellationDiscarded, sample: sample(3), at: 12)
        a.observe(.rejected(.oversize), sample: sample(20, kind: .audio), at: 12)
        a.observe(.rejected(.full), sample: LiveIngressSampleMetadata(kind: .unknown, sourcePTS: .invalid), at: 12)
        let t = a.snapshot.totalDispositions
        #expect(t[.admitted]?[.video]?.count == 2)
        #expect(t[.admitted]?[.video]?.minimumSourcePTS?.value == 3)
        #expect(t[.admitted]?[.video]?.maximumSourcePTS?.value == 9)
        #expect(t[.admitted]?[.video]?.minimumSourcePTS?.timescale == 30)
        #expect(t[.overflowEvicted]?[.video]?.count == 1)
        #expect(t[.cancellationDiscarded]?[.video]?.count == 1)
        #expect(t[.rejected(.oversize)]?[.audio]?.count == 1)
        #expect(t[.rejected(.full)]?[.unknown]?.invalidPTSCount == 1)
    }

    @Test func epochDiscontinuityPersistsAcrossRotationWithoutComparingEpochs() throws {
        var a = try make()
        a.observe(.admitted, sample: sample(10, epoch: 7), at: 10)
        a.observe(.admitted, sample: sample(1, epoch: 8), at: 15)
        a.observe(.admitted, sample: sample(20, epoch: 7), at: 16)
        let t = try #require(a.snapshot.totalDispositions[.admitted]?[.video])
        #expect(t.invalidity.contains(.epochDiscontinuity))
        #expect(t.minimumSourcePTS?.epoch == 7); #expect(t.maximumSourcePTS?.value == 10)
        #expect(t.lastSourcePTS?.value == 20)
        #expect(a.snapshot.current.dispositions[.admitted]?[.video]?.invalidity.contains(.epochDiscontinuity) == true)
    }

    @Test func badClockStillTracksDepthButQuarantinesWholeUnknownGap() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 100, at: 10)
        a.poll(at: 11)
        a.updateOccupancy(items: 0, bytes: 0, at: 10.5)
        a.observe(.dequeued, sample: sample(), at: .nan)
        var s = a.poll(at: 14)
        near(s.totalOccupancy.knownDuration, 1); near(s.totalOccupancy.unknownDuration, 3)
        near(s.totalOccupancy.maxPressureSeconds, 1)
        #expect(s.totalOccupancy.meanMaxPressure == nil)
        #expect(s.currentItems == 0); #expect(s.currentBytes == 0)
        #expect(s.rejectedClockOperationCount == 2); #expect(s.unassignedDispositionCount == 1)
        #expect(s.totalDispositions[.dequeued]?[.video]?.count == 1)
        #expect(s.current.dispositions[.dequeued] == nil)
        #expect(s.invalidity.contains(.invalidMonotonicClock))
        s = a.poll(at: 15)
        near(s.totalOccupancy.knownDuration, 2); near(s.totalOccupancy.unknownDuration, 3)
    }

    @Test func invalidGapAcrossWindowsNeverMasqueradesAsHealthyZero() throws {
        var a = try make()
        a.updateOccupancy(items: 2, bytes: 50, at: .infinity)
        let s = a.poll(at: 100)
        #expect(s.completed.count == 2)
        #expect(s.completed.allSatisfy { $0.occupancy.knownDuration == 0 && $0.occupancy.meanMaxPressure == nil })
        near(s.totalOccupancy.unknownDuration, 90)
        a.poll(at: 102)
        near(a.snapshot.totalOccupancy.itemSeconds, 1)
    }

    @Test func closeFreezesAtTrustedTimeOnInvalidClockAndCannotDilutePressure() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 100, at: 10)
        a.poll(at: 12)
        let terminal = a.close(at: -1)
        a.poll(at: 100); a.close(at: 200)
        a.updateOccupancy(items: 0, bytes: 0, at: 300)
        a.observe(.admitted, sample: sample(), at: 400)
        #expect(a.snapshot.current.monotonicEnd == 12)
        #expect(a.snapshot.current.isClosed)
        #expect(a.snapshot.rejectedClockOperationCount == terminal.rejectedClockOperationCount)
        #expect(a.snapshot.totalDispositions.isEmpty)
        near(a.snapshot.totalOccupancy.maxPressureSeconds, 2)
        #expect(a.snapshot.invalidity.contains(.invalidMonotonicClock))
    }

    @Test func countersAndOmittedCoverageSaturateWithoutWrapping() throws {
        var a = try make(history: 1, limit: 2)
        for _ in 0..<4 { a.observe(.admitted, sample: sample(), at: 10) }
        for _ in 0..<4 { a.poll(at: -1) }
        a.poll(at: 40); a.poll(at: 45)
        #expect(a.snapshot.totalDispositions[.admitted]?[.video]?.count == 2)
        #expect(a.snapshot.rejectedClockOperationCount == 2)
        #expect(a.snapshot.omittedCompletedWindowCount == 2)
        #expect(a.snapshot.invalidity.contains(.counterOverflow))
    }

    @Test func invalidDepthCannotCreateNegativeOrExcessArea() throws {
        var a = try make()
        a.updateOccupancy(items: 5, bytes: -1, at: 11)
        a.poll(at: 12)
        a.updateOccupancy(items: 2, bytes: 50, at: 13)
        let s = a.poll(at: 14)
        #expect(s.invalidity.contains(.invalidOccupancy))
        near(s.totalOccupancy.unknownDuration, 2)
        near(s.totalOccupancy.knownDuration, 2)
        near(s.totalOccupancy.maxPressureSeconds, 0.5)
        #expect(s.totalOccupancy.maxPressureSeconds.isFinite)
    }

    @Test func impossibleItemByteRelationshipsQuarantineOccupancy() throws {
        for (items, bytes) in [(0, 1), (1, 0), (2, 1)] {
            var a = try make()
            a.updateOccupancy(items: items, bytes: bytes, at: 10)
            let s = a.poll(at: 12)
            #expect(s.currentItems == items); #expect(s.currentBytes == bytes)
            #expect(s.invalidity.contains(.invalidOccupancy))
            near(s.totalOccupancy.knownDuration, 0)
            near(s.totalOccupancy.unknownDuration, 2)
            #expect(s.totalOccupancy.meanMaxPressure == nil)
            a.updateOccupancy(items: 2, bytes: 2, at: 12)
            a.poll(at: 13)
            near(a.snapshot.totalOccupancy.knownDuration, 1)
            near(a.snapshot.totalOccupancy.maxPressureSeconds, 0.5)
        }
    }

    @Test func configurationAndExtremeFiniteClockBoundsMatchVideoConvention() throws {
        for bad in [-1.0, .nan, .infinity, 1e12 + 1] {
            #expect(throws: LiveIngressObservationError.invalidConfiguration) {
                try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: bad, maxItems: 1, maxBytes: 1)
            }
        }
        #expect(throws: LiveIngressObservationError.invalidConfiguration) {
            try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 0, maxItems: 0, maxBytes: 1)
        }
        var a = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 0, maxItems: .max,
            maxBytes: .max, windowDuration: 1.0 / 1024, completedWindowLimit: 1)
        a.updateOccupancy(items: .max, bytes: .max, at: 0)
        let s = a.poll(at: 1e12)
        near(s.totalOccupancy.maxPressureSeconds, 1e12)
        #expect(s.completed.count == 1); #expect(s.totalOccupancy.maxPressureSeconds.isFinite)
    }
}
