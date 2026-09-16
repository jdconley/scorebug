import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

final class WorkerSourceIntervalObservationTests: XCTestCase {
    private let attempt = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let epoch = "22222222-2222-2222-2222-222222222222"
    private let reader = "33333333-3333-3333-3333-333333333333"
    private let publisher = "44444444-4444-4444-4444-444444444444"
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording-1", matchID: "game-1", broadcastGeneration: 1,
              publishingAttemptID: attempt, appliedProfileRevision: 1)
    }
    private func history(scope replacement: VideoFrameObservationScope? = nil) throws -> VideoSourceHistorySnapshot {
        var h = try VideoSourceHistory(scope: replacement ?? scope, capacity: 1024)
        for i in 0..<1000 {
            let pts = CMTime(value: Int64(i), timescale: 30)
            h.observe(.captureVideo, sourcePTS: pts, at: Double(i) / 30)
            h.observe(.encodedVideo, sourcePTS: pts, at: Double(i) / 30)
        }
        return h.snapshot
    }
    private func clock(scope replacement: VideoFrameObservationScope? = nil, closed: Bool = false) -> PublishingClockObservation {
        .init(scope: replacement ?? scope,
              transportClock: PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1)!, isClosed: closed)
    }
    private func response(sequence: Int64, first: Int64? = nil, count: Int64 = 150) -> WorkerMediaStatusResponse {
        let start = first ?? (sequence - 1) * 150
        let end = sequence * 150 - 1
        let window = DecodedVideoWindow(sequence: sequence, durationMs: 5000, ageMs: 100,
            firstPTS: count == 0 ? nil : start * 3000 - 1919,
            lastPTS: count == 0 ? nil : end * 3000 - 1919,
            freshFrames: count, duplicateFrames: 0, reorderedFrames: 0, valid: true)
        let observation = WorkerObservation(gameId: "game-1", generation: 1, state: .producingOutput,
            reason: nil, attempt: 1, frame: 150, outTimeUs: 1000, scoreRevision: 1,
            decodedVideo: .init(completed: window, invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1"))
        let publication = WorkerPublication(readerId: reader, publisherId: publisher,
            publishingAttemptId: attempt.uuidString.lowercased(),
            clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "10919"))
        return .init(status: .init(gameId: "game-1", generation: 1, workerId: "worker-1", state: .producingOutput,
            observation: observation, observedAt: "2040-01-01T00:00:00Z", expiresAt: "2040-01-01T00:00:05Z",
            decodedVideoAgeUpperBoundMs: 200, workerEpoch: epoch, publication: publication), serverTime: "2040-01-01T00:00:00Z")
    }
    @discardableResult
    private func feed(_ tracker: inout WorkerSourceIntervalTracker, _ response: WorkerMediaStatusResponse,
                      at instant: ContinuousClock.Instant, history replacement: VideoSourceHistorySnapshot? = nil,
                      clock clockReplacement: PublishingClockObservation? = nil) throws -> WorkerSourceIntervalObservation? {
        tracker.observe(response: response, history: try replacement ?? history(), clock: clockReplacement ?? clock(),
                        receivedAt: instant, requestDuration: .milliseconds(50))
    }

    func testConsecutiveReportsProduceMatchedCountsIncludingLeadingLoss() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        XCTAssertNil(try feed(&tracker, response(sequence: 1), at: now))
        XCTAssertEqual(tracker.gapReason, .acquisition)
        let result = try XCTUnwrap(feed(&tracker, response(sequence: 2, first: 155, count: 145), at: now + .seconds(1)))
        XCTAssertEqual(result.workerEpoch, epoch)
        XCTAssertEqual(result.publication.readerId, reader)
        XCTAssertEqual(result.previousSequence, 1)
        XCTAssertEqual(result.sequence, 2)
        XCTAssertEqual(result.interval.capturedFrames, 150)
        XCTAssertEqual(result.interval.encodedNotDecodedFrames, 5)
        XCTAssertEqual(result.interval.leadingMissingEncodedFrames, 5)
        XCTAssertEqual(result.freshness.ageUpperBound(at: now + .seconds(1)), .milliseconds(250))
        XCTAssertNil(tracker.gapReason)
    }

    func testDuplicateAgeRefreshDoesNotRefreshMeasuredIntervalAge() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        try feed(&tracker, response(sequence: 2), at: now + .seconds(1))
        var duplicate = response(sequence: 2)
        duplicate.status.observation?.decodedVideo?.completed?.ageMs = 1100
        duplicate.status.decodedVideoAgeUpperBoundMs = 1200
        let same = try XCTUnwrap(feed(&tracker, duplicate, at: now + .seconds(2)))
        XCTAssertEqual(same.sequence, 2)
        XCTAssertEqual(same.freshness.ageUpperBound(at: now + .seconds(2)), .milliseconds(1250))
        XCTAssertNil(same.freshness.ageUpperBound(at: now + .seconds(6)), "Duplicate status must not extend the original measurement lease")
        tracker.expire(at: now + .seconds(6))
        XCTAssertNil(tracker.latest)
        XCTAssertEqual(tracker.gapReason, .expired)
        XCTAssertNotNil(try feed(&tracker, response(sequence: 3), at: now + .milliseconds(6100)))
    }

    func testContradictoryDuplicateCannotResurrectMeasurement() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        try feed(&tracker, response(sequence: 2), at: now)
        let bad = response(sequence: 2, count: 149)
        XCTAssertNil(try feed(&tracker, bad, at: now))
        XCTAssertEqual(tracker.gapReason, .contradiction)
        XCTAssertNil(try feed(&tracker, response(sequence: 2), at: now))
        XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now))
        XCTAssertNotNil(try feed(&tracker, response(sequence: 4), at: now))
    }

    func testSkippedAndRewoundReportsRequireNewConsecutiveBaseline() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now))
        XCTAssertEqual(tracker.gapReason, .sequenceGap)
        XCTAssertNotNil(try feed(&tracker, response(sequence: 4), at: now))
        XCTAssertNil(try feed(&tracker, response(sequence: 2), at: now))
        XCTAssertEqual(tracker.gapReason, .rewind)
        XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now))
        XCTAssertNil(try feed(&tracker, response(sequence: 4), at: now))
        XCTAssertNil(try feed(&tracker, response(sequence: 5), at: now))
        XCTAssertNotNil(try feed(&tracker, response(sequence: 6), at: now))
    }

    func testWorkerEpochAttemptReaderAndPublisherChangesDoNotJoinIntervals() throws {
        for field in ["epoch", "attempt", "reader", "publisher", "origin"] {
            var tracker = WorkerSourceIntervalTracker()
            let now = ContinuousClock.now
            try feed(&tracker, response(sequence: 1), at: now)
            var changed = response(sequence: 2)
            switch field {
            case "epoch": changed.status.workerEpoch = UUID().uuidString.lowercased()
            case "attempt": changed.status.observation?.attempt = 2
            case "reader": changed.status.publication?.readerId = UUID().uuidString.lowercased()
            case "publisher": changed.status.publication?.publisherId = UUID().uuidString.lowercased()
            default: changed.status.publication?.clock.originPTS = "10920"
            }
            XCTAssertNil(try feed(&tracker, changed, at: now), field)
            XCTAssertEqual(tracker.gapReason, .scopeChanged, field)
        }
    }

    func testMissingPublicationUnknownClockAndMismatchedNativeAttemptStayUnknown() throws {
        for field in ["publication", "clock", "attempt", "generation", "game", "stale"] {
            var tracker = WorkerSourceIntervalTracker()
            let now = ContinuousClock.now
            try feed(&tracker, response(sequence: 1), at: now)
            var changed = response(sequence: 2)
            switch field {
            case "publication": changed.status.publication = nil
            case "clock": changed.status.observation?.decodedVideo?.clock = nil
            case "attempt": changed.status.publication?.publishingAttemptId = UUID().uuidString.lowercased()
            case "generation": changed.status.generation = 2; changed.status.observation?.generation = 2
            case "game": changed.status.gameId = "other"; changed.status.observation?.gameId = "other"
            default: changed.status.expiresAt = changed.serverTime
            }
            XCTAssertNil(try feed(&tracker, changed, at: now), field)
            XCTAssertNil(tracker.latest)
            XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now))
        }
    }

    func testRecordingProfileAndNativeClockChangesResetScope() throws {
        let now = ContinuousClock.now
        for field in ["recording", "profile", "nativeGeneration"] {
            var tracker = WorkerSourceIntervalTracker()
            try feed(&tracker, response(sequence: 1), at: now)
            let changedScope = VideoFrameObservationScope(recordingID: field == "recording" ? "other" : "recording-1",
                matchID: "game-1", broadcastGeneration: 1, publishingAttemptID: attempt,
                appliedProfileRevision: field == "profile" ? 2 : 1)
            let changedClock = PublishingClockObservation(scope: changedScope,
                transportClock: PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: field == "nativeGeneration" ? 2 : 1)!, isClosed: false)
            XCTAssertNil(try feed(&tracker, response(sequence: 2), at: now,
                history: history(scope: changedScope), clock: changedClock))
            XCTAssertEqual(tracker.gapReason, .scopeChanged)
        }
    }

    func testEmptyDuplicateReorderedAndInvalidWindowsCannotEstablishDenominator() throws {
        for field in ["empty", "duplicate", "reorder", "invalid"] {
            var tracker = WorkerSourceIntervalTracker()
            let now = ContinuousClock.now
            try feed(&tracker, response(sequence: 1), at: now)
            var bad = response(sequence: 2, count: field == "empty" ? 0 : 150)
            switch field {
            case "duplicate": bad.status.observation?.decodedVideo?.completed?.duplicateFrames = 1
            case "reorder": bad.status.observation?.decodedVideo?.completed?.reorderedFrames = 1
            case "invalid": bad.status.observation?.decodedVideo?.completed?.valid = false
            default: break
            }
            XCTAssertNil(try feed(&tracker, bad, at: now), field)
            XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now))
            XCTAssertNotNil(try feed(&tracker, response(sequence: 4), at: now))
        }
    }

    func testExpiryAndClearDoNotPreservePriorBaseline() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        try feed(&tracker, response(sequence: 2), at: now)
        tracker.expire(at: now + .seconds(6))
        XCTAssertNil(tracker.latest)
        XCTAssertEqual(tracker.gapReason, .expired)
        XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now + .seconds(6)))
        tracker.clear()
        XCTAssertNil(try feed(&tracker, response(sequence: 4), at: now + .seconds(7)))
    }

    func testExpiredBaselineCannotJoinEvenWithoutHealthPolling() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        XCTAssertNil(try feed(&tracker, response(sequence: 2), at: now + .seconds(6)))
        XCTAssertNotNil(try feed(&tracker, response(sequence: 3), at: now + .seconds(7)))
    }

    func testNormalWindowAgeProgressionKeepsHistoricalAnchorUnderFreshReportLease() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        var aged = response(sequence: 1)
        aged.status.observation?.decodedVideo?.completed?.ageMs = 4100
        aged.status.decodedVideoAgeUpperBoundMs = 4200
        XCTAssertNil(try feed(&tracker, aged, at: now + .seconds(4)))
        tracker.expire(at: now + .seconds(5))
        XCTAssertNotNil(try feed(&tracker, response(sequence: 2), at: now + .seconds(5)))
    }

    func testClosedMismatchedAndInvalidNativeHistoryCannotMatch() throws {
        var tracker = WorkerSourceIntervalTracker()
        let now = ContinuousClock.now
        try feed(&tracker, response(sequence: 1), at: now)
        XCTAssertNil(try feed(&tracker, response(sequence: 2), at: now, clock: clock(closed: true)))
        var invalid = try VideoSourceHistory(scope: scope)
        invalid.observe(.captureVideo, sourcePTS: .invalid, at: 1)
        XCTAssertNil(try feed(&tracker, response(sequence: 3), at: now, history: invalid.snapshot))
        var closed = try VideoSourceHistory(scope: scope)
        closed.close()
        XCTAssertNil(try feed(&tracker, response(sequence: 4), at: now, history: closed.snapshot))
    }
    private func withProcessing(_ original: WorkerMediaStatusResponse, pending: Int64 = 1) -> WorkerMediaStatusResponse {
        var response = original
        let window = response.status.observation!.decodedVideo!.completed!
        response.status.observation!.processing = WorkerProcessingReport(
            scopeID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", encoder: "videotoolbox",
            previousSequence: window.sequence - 1, sequence: window.sequence, firstPTS: window.firstPTS!,
            interval: .init(sourceStartExclusive: (window.sequence - 1) * 450000 - 3000 - 1919,
                sourceEndInclusive: window.lastPTS!, decodedFrames: window.freshFrames,
                submittedFrames: window.freshFrames, completedFrames: window.freshFrames - pending,
                pendingFrames: pending, omittedBeforeEncoderFrames: 0, filterDuration: .init(meanMs: 1, maximumMs: 2),
                processingDuration: pending == 0 ? .init(meanMs: 400, maximumMs: 650) : nil))
        return response
    }
    func testProcessingMatchesNativeSourceAndUpdatesPendingOnRepeatedWindow() throws {
        let now = ContinuousClock.now
        var tracker = WorkerSourceIntervalTracker()
        try feed(&tracker, response(sequence: 1), at: now)
        let pending = try XCTUnwrap(feed(&tracker, withProcessing(response(sequence: 2)), at: now + .seconds(1)))
        XCTAssertEqual(pending.processing?.interval.pendingFrames, 1)
        XCTAssertNil(pending.processing?.interval.processingDuration)
        let complete = try XCTUnwrap(feed(&tracker, withProcessing(response(sequence: 2), pending: 0), at: now + .seconds(2)))
        XCTAssertEqual(complete.processing?.interval.pendingFrames, 0)
        XCTAssertEqual(complete.processing?.interval.processingDuration?.maximumMs, 650)
        XCTAssertEqual(complete.freshness.ageUpperBound(at: now + .seconds(2)), .milliseconds(1250))
        let omitted = try XCTUnwrap(feed(&tracker, response(sequence: 2), at: now + .seconds(3)))
        XCTAssertNil(omitted.processing)
    }
    func testProcessingWithWrongExclusiveAnchorRemainsUnknownOnValidNativeInterval() throws {
        let now = ContinuousClock.now
        var tracker = WorkerSourceIntervalTracker()
        try feed(&tracker, response(sequence: 1), at: now)
        var report = withProcessing(response(sequence: 2), pending: 0)
        report.status.observation!.processing!.interval.sourceStartExclusive -= 1
        let result = try XCTUnwrap(feed(&tracker, report, at: now + .seconds(1)))
        XCTAssertEqual(result.interval.decodedFrames, 150)
        XCTAssertNil(result.processing)
    }
    func testMalformedProcessingCannotEraseValidSourceCorrespondence() throws {
        let now = ContinuousClock.now
        var tracker = WorkerSourceIntervalTracker()
        try feed(&tracker, response(sequence: 1), at: now)
        var report = withProcessing(response(sequence: 2), pending: 0)
        report.status.observation!.processing!.interval.completedFrames = 999
        let result = try XCTUnwrap(feed(&tracker, report, at: now + .seconds(1)))
        XCTAssertEqual(result.interval.decodedFrames, 150)
        XCTAssertNil(result.processing)
    }

}
