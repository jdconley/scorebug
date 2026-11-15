import CoreMedia
import Foundation
import Testing
@testable import ScorebugMedia

struct VideoFrameObservationTests {
    private let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
        broadcastGeneration: 4, publishingAttemptID: UUID(), appliedProfileRevision: 2)
    private func pts(_ value: Int64, scale: Int32 = 30, epoch: Int64 = 0) -> CMTime {
        CMTime(value: value, timescale: scale, flags: .valid, epoch: epoch)
    }
    private func make(history: Int = 4) throws -> VideoFrameObservationAccumulator {
        try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 10,
            windowDuration: 1, completedWindowLimit: history)
    }

    @Test func zeroAndEquivalentRationalTimesAreFreshThenDuplicate() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: .zero, at: 10)
        value.observe(.captureVideo, sourcePTS: pts(1), at: 10.1)
        value.observe(.captureVideo, sourcePTS: pts(2, scale: 60), at: 10.2)
        let s = value.snapshot.current.captureVideo
        #expect(s.callbackCount == 3)
        #expect(s.advancingSourcePTSCount == 2)
        #expect(s.duplicateSourcePTSCount == 1)
        #expect(s.firstSourcePTS == .zero)
        #expect(s.lastSourcePTS?.timescale == 60)
        #expect(s.highWaterSourcePTS == pts(1))
    }

    @Test func boundaryRotationPrecedesObservationAndRetainsHighWater() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(5), at: 10.9)
        value.observe(.captureVideo, sourcePTS: pts(10, scale: 60), at: 11)
        value.poll(at: 11.7)
        #expect(value.snapshot.completed.count == 1)
        #expect(value.snapshot.completed[0].captureVideo.advancingSourcePTSCount == 1)
        #expect(value.snapshot.completed[0].monotonicStart == 10)
        #expect(value.snapshot.completed[0].monotonicEnd == 11)
        #expect(value.snapshot.current.monotonicStart == 11)
        #expect(value.snapshot.current.captureVideo.callbackCount == 1)
        #expect(value.snapshot.current.captureVideo.duplicateSourcePTSCount == 1)
        #expect(value.snapshot.current.captureVideo.advancingSourcePTSCount == 0)
    }

    @Test func delayedPollPreservesCallbackWindowOwnershipAndFullDuration() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(1), at: 10.99)
        value.observe(.captureVideo, sourcePTS: pts(2), at: 11.01)
        value.poll(at: 12.4)
        #expect(value.snapshot.completed.map(\.captureVideo.callbackCount) == [1, 1])
        #expect(value.snapshot.completed.map { $0.monotonicEnd - $0.monotonicStart } == [1, 1])
        #expect(value.snapshot.current.captureVideo.callbackCount == 0)
        #expect(value.snapshot.current.captureVideo.lastObservationTime == 11.01)
        #expect(value.snapshot.current.isPartial)
    }

    @Test func reorderAndNonNumericPTSDoNotAdvanceHighWater() throws {
        var value = try make()
        for (index, timestamp) in [pts(10), pts(9), CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity, pts(11)].enumerated() {
            value.observe(.captureVideo, sourcePTS: timestamp, at: 10 + Double(index) / 10)
        }
        let s = value.snapshot.current.captureVideo
        #expect(s.callbackCount == 7)
        #expect(s.advancingSourcePTSCount == 2)
        #expect(s.reorderedSourcePTSCount == 1)
        #expect(s.invalidSourcePTSCount == 4)
        #expect(s.highWaterSourcePTS == pts(11))
        #expect(s.invalidity.contains(.invalidSourcePTS))
    }

    @Test func epochDiscontinuityPermanentlyQuarantinesFreshnessForOnlyThatStage() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(5, epoch: 7), at: 10)
        value.observe(.captureVideo, sourcePTS: pts(6, epoch: 8), at: 10.1)
        value.observe(.captureVideo, sourcePTS: pts(7, epoch: 7), at: 11)
        value.observe(.encodedVideo, sourcePTS: pts(1, epoch: 8), at: 11)
        let s = value.snapshot.current
        #expect(s.captureVideo.advancingSourcePTSCount == 0)
        #expect(s.captureVideo.discontinuousSourcePTSCount == 1)
        #expect(s.captureVideo.invalidity.contains(.epochDiscontinuity))
        #expect(s.captureVideo.highWaterSourcePTS == pts(5, epoch: 7))
        #expect(s.encodedVideo.advancingSourcePTSCount == 1)
        #expect(s.encodedVideo.invalidity.isEmpty)
    }

    @Test func emptyStartupAndLongGapStayBoundedAndRetainCoveredInterval() throws {
        var value = try make(history: 2)
        value.poll(at: 1_000_000_010.5)
        let s = value.snapshot
        #expect(s.completed.count == 2)
        #expect(s.completed[0].monotonicStart == 10)
        #expect(s.completed[0].coveredWindowCount == 1)
        #expect(s.completed[1].coveredWindowCount == 999_999_999)
        #expect(s.completed[1].monotonicStart == 11)
        #expect(s.completed[1].monotonicEnd == 1_000_000_010)
        #expect(s.completed[1].isCoalescedEmptyGap)
        #expect(s.current.captureVideo.firstObservationTime == nil)
        #expect(s.current.monotonicStart == 1_000_000_010)
        value.observe(.captureVideo, sourcePTS: .zero, at: 1_000_000_010.5)
        value.poll(at: 1_000_000_011)
        #expect(value.snapshot.completed.count == 2)
        #expect(value.snapshot.omittedCompletedWindowCount == 1)
        #expect(value.snapshot.omittedThroughMonotonicTime == 11)
        #expect(value.snapshot.current.captureVideo.firstObservationTime == 1_000_000_010.5)
    }

    @Test func rejectedClocksAreObservableWithoutChangingPTSOrWindow() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(5), at: 10.5)
        for time in [10.4, Double.nan, Double.infinity, -1, 1e15] {
            let accepted = value.observe(.captureVideo, sourcePTS: pts(100), at: time)
            #expect(!accepted)
        }
        value.poll(at: 10.5)
        #expect(value.snapshot.rejectedClockOperationCount == 5)
        #expect(value.snapshot.invalidity.contains(.invalidMonotonicClock))
        #expect(value.snapshot.current.captureVideo.highWaterSourcePTS == pts(5))
        #expect(value.snapshot.current.captureVideo.callbackCount == 1)
        value.observe(.captureVideo, sourcePTS: pts(6), at: 11)
        #expect(value.snapshot.current.captureVideo.advancingSourcePTSCount == 1)
        #expect(value.snapshot.invalidity.contains(.invalidMonotonicClock))
    }

    @Test func validatesInitialClockAndConfiguration() throws {
        for anchor in [-1, .nan, .infinity, 1e15] {
            #expect(throws: VideoFrameObservationError.invalidConfiguration) {
                try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: anchor)
            }
        }
        for duration in [0, -1, .nan, .infinity, 0.000001, 100_000] {
            #expect(throws: VideoFrameObservationError.invalidConfiguration) {
                try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0, windowDuration: duration)
            }
        }
        for limit in [-1, 0, 129, 130, Int.max] {
            #expect(throws: VideoFrameObservationError.invalidConfiguration) {
                try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0, completedWindowLimit: limit)
            }
        }
        let zero = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        #expect(zero.snapshot.current.monotonicStart == 0)
    }

    @Test func explicitHistoryRetainsTenMinutesOfSamplesThenEvictsAt128Windows() throws {
        var value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0,
            completedWindowLimit: 128)
        for window in 0..<130 {
            for frame in 0..<150 {
                let sourceFrame = Int64(window * 150 + frame)
                let time = Double(window * 5) + Double(frame) / 30
                let captured = value.observe(.captureVideo, sourcePTS: pts(sourceFrame), at: time)
                let encoded = value.observe(.encodedVideo, sourcePTS: pts(sourceFrame), at: time)
                #expect(captured && encoded)
            }
            value.poll(at: Double((window + 1) * 5))
            if window == 119 || window == 127 {
                let snapshot = value.snapshot
                #expect(snapshot.completed.count == window + 1)
                #expect(snapshot.omittedCompletedWindowCount == 0)
                #expect(snapshot.omittedThroughMonotonicTime == nil)
                #expect(snapshot.completed.first?.monotonicStart == 0)
                #expect(snapshot.completed.last?.monotonicEnd == Double((window + 1) * 5))
                #expect(snapshot.completed.allSatisfy {
                    !$0.isPartial && !$0.isCoalescedEmptyGap && $0.coveredWindowCount == 1
                        && $0.captureVideo.callbackCount == 150 && $0.encodedVideo.callbackCount == 150
                        && $0.captureVideo.advancingSourcePTSCount == 150
                        && $0.encodedVideo.advancingSourcePTSCount == 150
                })
            }
        }
        let snapshot = value.close(at: 650)
        #expect(snapshot.completed.count == 128)
        #expect(snapshot.omittedCompletedWindowCount == 2)
        #expect(snapshot.omittedThroughMonotonicTime == 10)
        #expect(snapshot.completed.map(\.monotonicStart) == (2..<130).map { Double($0 * 5) })
        #expect(snapshot.completed.last?.monotonicEnd == 650)
        #expect(snapshot.completed.first?.captureVideo.firstSourcePTS == pts(300))
        #expect(snapshot.completed.last?.encodedVideo.lastSourcePTS == pts(19_499))
        #expect(snapshot.current.captureVideo.callbackCount == 0)
        #expect(snapshot.current.encodedVideo.callbackCount == 0)
        #expect(snapshot.current.isClosed)
        #expect(snapshot.invalidity.isEmpty)
        #expect(snapshot.rejectedClockOperationCount == 0)
    }

    @Test func defaultHistoryStillRetainsOnlyEightSampledWindows() throws {
        var value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        for window in 0..<10 {
            value.observe(.captureVideo, sourcePTS: pts(Int64(window)), at: Double(window * 5))
            value.poll(at: Double((window + 1) * 5))
        }
        let snapshot = value.snapshot
        #expect(snapshot.windowDuration == 5)
        #expect(snapshot.completed.count == 8)
        #expect(snapshot.completed.map(\.monotonicStart) == (2..<10).map { Double($0 * 5) })
        #expect(snapshot.completed.allSatisfy { $0.captureVideo.callbackCount == 1 && !$0.isCoalescedEmptyGap })
        #expect(snapshot.omittedCompletedWindowCount == 2)
        #expect(snapshot.omittedThroughMonotonicTime == 10)
    }

    @Test func supportsExplicitHistoryBoundsThrough128() throws {
        for limit in [1, 64, 65, 128] {
            let value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0,
                completedWindowLimit: limit)
            #expect(value.snapshot.completed.isEmpty)
            #expect(value.snapshot.omittedCompletedWindowCount == 0)
        }
    }

    @Test func countersSaturateAndRemainInvalidAcrossRotation() throws {
        var value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 10,
            windowDuration: 1, completedWindowLimit: 1, counterLimit: 2)
        for _ in 0..<5 { value.observe(.captureVideo, sourcePTS: .invalid, at: 10) }
        #expect(value.snapshot.current.captureVideo.callbackCount == 2)
        #expect(value.snapshot.current.captureVideo.invalidSourcePTSCount == 2)
        #expect(value.snapshot.current.captureVideo.invalidity.contains(.counterOverflow))
        for _ in 0..<5 { value.poll(at: .nan) }
        #expect(value.snapshot.rejectedClockOperationCount == 2)
        value.poll(at: 100)
        value.poll(at: 101)
        #expect(value.snapshot.omittedCompletedWindowCount == 2)
        #expect(value.snapshot.invalidity.contains(.counterOverflow))
        #expect(value.snapshot.current.captureVideo.invalidity.contains(.counterOverflow))
    }

    @Test func closureIsFinalPartialIdempotentAndOldOwnerCannotAffectReplacement() throws {
        let old = try VideoFrameObservationOwner(scope: scope, windowDuration: 86400)
        old.observe(.encodedVideo, sourcePTS: pts(1))
        let closed = old.close()
        #expect(closed.isClosed)
        #expect(closed.current.isClosed)
        #expect(closed.current.isPartial)
        #expect(closed.current.monotonicEnd >= closed.monotonicAnchor)
        #expect(!old.observe(.encodedVideo, sourcePTS: pts(2)))
        #expect(old.close().rejectedClockOperationCount == 0)
        #expect(old.poll().current.monotonicEnd == closed.current.monotonicEnd)
        let replacementScope = VideoFrameObservationScope(recordingID: scope.recordingID,
            matchID: scope.matchID, broadcastGeneration: scope.broadcastGeneration,
            publishingAttemptID: UUID(), appliedProfileRevision: scope.appliedProfileRevision)
        let replacement = try VideoFrameObservationOwner(scope: replacementScope)
        replacement.observe(.encodedVideo, sourcePTS: .zero)
        #expect(old.snapshot.current.encodedVideo.callbackCount == 1)
        #expect(replacement.snapshot.current.encodedVideo.advancingSourcePTSCount == 1)
        #expect(replacement.snapshot.scope != old.snapshot.scope)
    }

    @Test func closeWithInvalidClockFreezesAtLastTrustedTimeAndMarksInvalid() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: .zero, at: 10.5)
        let result = value.close(at: 10.4)
        #expect(result.isClosed)
        #expect(result.current.monotonicEnd == 10.5)
        #expect(result.invalidity.contains(.invalidMonotonicClock))
        let accepted = value.observe(.captureVideo, sourcePTS: pts(1), at: 11)
        #expect(!accepted)
    }

    @Test func bothStagesUseSameScopeAnchorAndIndependentCounts() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(100), at: 10.2)
        value.observe(.encodedVideo, sourcePTS: .zero, at: 10.2)
        value.observe(.captureVideo, sourcePTS: pts(100), at: 10.2)
        #expect(value.snapshot.scope == scope)
        #expect(value.snapshot.monotonicAnchor == 10)
        #expect(value.snapshot.current.captureVideo.callbackCount == 2)
        #expect(value.snapshot.current.captureVideo.duplicateSourcePTSCount == 1)
        #expect(value.snapshot.current.encodedVideo.callbackCount == 1)
        #expect(value.snapshot.current.encodedVideo.advancingSourcePTSCount == 1)
    }


    @Test func malformedTimescalesAreInvalidEvenWhenNumericFlagIsSet() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: .zero, at: 10)
        value.observe(.captureVideo, sourcePTS: pts(100, scale: 0), at: 10.1)
        value.observe(.captureVideo, sourcePTS: pts(100, scale: -1), at: 10.2)
        let s = value.snapshot.current.captureVideo
        #expect(s.invalidSourcePTSCount == 2)
        #expect(s.advancingSourcePTSCount == 1)
        #expect(s.highWaterSourcePTS == .zero)
        #expect(s.lastSourcePTS == .zero)
    }

    @Test func legalClockExtremesRetainRepresentablePositiveWindows() throws {
        var value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0,
            windowDuration: 1.0 / 1024, completedWindowLimit: 2)
        value.observe(.captureVideo, sourcePTS: .zero, at: 1e12)
        let s = value.snapshot
        #expect(s.completed.count == 2)
        #expect(s.current.monotonicStart == 1e12)
        #expect(s.current.scheduledMonotonicEnd > s.current.monotonicStart)
        #expect(s.current.captureVideo.callbackCount == 1)
        var lateAnchor = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 1e12,
            windowDuration: 1.0 / 1024)
        lateAnchor.observe(.captureVideo, sourcePTS: .zero, at: 1e12)
        #expect(lateAnchor.snapshot.current.scheduledMonotonicEnd > 1e12)
        #expect(throws: VideoFrameObservationError.invalidConfiguration) {
            try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 1e12,
                windowDuration: Double.leastNonzeroMagnitude)
        }
    }

    @Test func fractionalAnchorsAndDurationsHaveExactRepresentedBoundaryOwnership() throws {
        for anchor in [0.0, 0.1, 12345.6789, 999_999_999_999.0] {
            for duration in [0.1, 1.0 / 1024, 0.003] {
                var value = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: anchor,
                    windowDuration: duration)
                let boundary = anchor + duration
                value.observe(.captureVideo, sourcePTS: .zero, at: boundary.nextDown)
                value.observe(.captureVideo, sourcePTS: pts(1), at: boundary)
                #expect(value.snapshot.completed.count == 1)
                #expect(value.snapshot.completed[0].captureVideo.callbackCount == 1)
                #expect(value.snapshot.current.monotonicStart == boundary)
                #expect(value.snapshot.current.captureVideo.callbackCount == 1)
            }
        }
    }

    @Test func lateCallbackAfterPollIsRejectedRatherThanReassigned() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: pts(5), at: 10.8)
        value.poll(at: 11.2)
        let accepted = value.observe(.captureVideo, sourcePTS: pts(6), at: 10.9)
        #expect(!accepted)
        #expect(value.snapshot.current.captureVideo.callbackCount == 0)
        #expect(value.snapshot.completed[0].captureVideo.callbackCount == 1)
        #expect(value.snapshot.rejectedClockOperationCount == 1)
        #expect(value.snapshot.current.captureVideo.highWaterSourcePTS == pts(5))
    }

    @Test func closeAtBoundaryPreservesFullIntervalAndTerminalZeroLengthPartial() throws {
        var value = try make()
        value.observe(.captureVideo, sourcePTS: .zero, at: 10)
        let s = value.close(at: 11)
        #expect(s.completed.count == 1)
        #expect(!s.completed[0].isPartial)
        #expect(s.completed[0].monotonicEnd - s.completed[0].monotonicStart == 1)
        #expect(s.current.isPartial && s.current.isClosed)
        #expect(s.current.monotonicStart == s.current.monotonicEnd)
        #expect(s.current.captureVideo.callbackCount == 0)
    }

    @Test func synchronizedOwnerAccountsForConcurrentCallbacksAndClosure() async throws {
        let owner = try VideoFrameObservationOwner(scope: scope, windowDuration: 86400)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 {
                        owner.observe(.captureVideo, sourcePTS: .zero)
                        owner.poll()
                    }
                }
            }
        }
        #expect(owner.snapshot.rejectedClockOperationCount == 0)
        #expect(owner.snapshot.invalidity.isEmpty)
        #expect(owner.snapshot.current.captureVideo.callbackCount == 800)
        #expect(owner.snapshot.current.captureVideo.advancingSourcePTSCount == 1)
        #expect(owner.snapshot.current.captureVideo.duplicateSourcePTSCount == 799)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    owner.close()
                    for _ in 0..<100 { owner.observe(.encodedVideo, sourcePTS: .zero) }
                }
            }
        }
        #expect(owner.snapshot.isClosed)
        #expect(owner.snapshot.current.encodedVideo.callbackCount == 0)
    }
}
