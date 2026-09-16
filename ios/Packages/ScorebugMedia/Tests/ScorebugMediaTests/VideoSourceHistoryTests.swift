import CoreMedia
import XCTest
@testable import ScorebugMedia

final class VideoSourceHistoryTests: XCTestCase {
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
              publishingAttemptID: UUID(), appliedProfileRevision: 1)
    }

    func testStagesRetainExactRationalTimesAndShareScope() throws {
        let scope = scope
        var history = try VideoSourceHistory(scope: scope)
        XCTAssertTrue(history.observe(.captureVideo, sourcePTS: CMTime(value: -1, timescale: 3), at: 0))
        XCTAssertTrue(history.observe(.encodedVideo, sourcePTS: CMTime(value: -1, timescale: 3), at: 0.1))
        XCTAssertTrue(history.observe(.captureVideo, sourcePTS: CMTime(value: 1, timescale: 7), at: 0.2))
        let result = history.snapshot
        XCTAssertEqual(result.scope, scope)
        XCTAssertEqual(result.capture.map(\.sourcePTS), [CMTime(value: -1, timescale: 3), CMTime(value: 1, timescale: 7)])
        XCTAssertEqual(result.capture.map(\.observedAt), [0, 0.2])
        XCTAssertEqual(result.encoded.map(\.sourcePTS), [CMTime(value: -1, timescale: 3)])
        XCTAssertNil(result.invalidity)
    }

    func testRingEvictsIndependentlyAndSnapshotsRemainImmutable() throws {
        var history = try VideoSourceHistory(scope: scope, capacity: 3)
        for i in 0..<3 { history.observe(.captureVideo, sourcePTS: CMTime(value: Int64(i), timescale: 30), at: Double(i)) }
        let before = history.snapshot
        for i in 3..<100 {
            history.observe(.captureVideo, sourcePTS: CMTime(value: Int64(i), timescale: 30), at: Double(i))
            if i == 99 { history.observe(.encodedVideo, sourcePTS: CMTime(value: Int64(i), timescale: 30), at: Double(i)) }
        }
        let after = history.snapshot
        XCTAssertEqual(before.capture.map { $0.sourcePTS.value }, [0, 1, 2])
        XCTAssertEqual(after.capture.map { $0.sourcePTS.value }, [97, 98, 99])
        XCTAssertEqual(after.omittedCaptureFrames, 97)
        XCTAssertEqual(after.encoded.count, 1)
        XCTAssertEqual(after.omittedEncodedFrames, 0)
    }

    func testCapacityOneAndBounds() throws {
        for capacity in [0, -1, 8193, Int.max] {
            XCTAssertThrowsError(try VideoSourceHistory(scope: scope, capacity: capacity))
        }
        var history = try VideoSourceHistory(scope: scope, capacity: 1)
        history.observe(.captureVideo, sourcePTS: .zero, at: 0)
        history.observe(.captureVideo, sourcePTS: CMTime(value: 1, timescale: 30), at: 1)
        XCTAssertEqual(history.snapshot.capture.count, 1)
        XCTAssertEqual(history.snapshot.omittedCaptureFrames, 1)
    }

    func testDuplicateEquivalentRationalAndReorderedPTSQuarantineHistory() throws {
        for invalid in [CMTime(value: 2, timescale: 60), CMTime(value: 0, timescale: 30)] {
            var history = try VideoSourceHistory(scope: scope)
            history.observe(.captureVideo, sourcePTS: CMTime(value: 1, timescale: 30), at: 0)
            XCTAssertFalse(history.observe(.captureVideo, sourcePTS: invalid, at: 1))
            XCTAssertEqual(history.snapshot.invalidity, .sourceOrder)
            XCTAssertFalse(history.observe(.captureVideo, sourcePTS: CMTime(value: 2, timescale: 30), at: 2))
            XCTAssertEqual(history.snapshot.capture.count, 1)
        }
    }

    func testMalformedAndNonzeroEpochPTSQuarantineHistory() throws {
        for pts in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                    CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1)] {
            var history = try VideoSourceHistory(scope: scope)
            XCTAssertFalse(history.observe(.encodedVideo, sourcePTS: pts, at: 0))
            XCTAssertEqual(history.snapshot.invalidity, .sourcePTS)
            XCTAssertFalse(history.observe(.captureVideo, sourcePTS: .zero, at: 1))
        }
    }

    func testInvalidAndReversedClockQuarantineAcrossStages() throws {
        for time in [-1, 0.5, .nan, .infinity, -.infinity] {
            var history = try VideoSourceHistory(scope: scope)
            history.observe(.captureVideo, sourcePTS: .zero, at: 1)
            XCTAssertFalse(history.observe(.encodedVideo, sourcePTS: .zero, at: time))
            XCTAssertEqual(history.snapshot.invalidity, .monotonicClock)
        }
    }

    func testCloseFreezesHistoryAndInvalidity() throws {
        var history = try VideoSourceHistory(scope: scope)
        history.observe(.captureVideo, sourcePTS: .zero, at: 1)
        history.close()
        XCTAssertFalse(history.observe(.captureVideo, sourcePTS: .invalid, at: .nan))
        history.close()
        XCTAssertTrue(history.snapshot.isClosed)
        XCTAssertEqual(history.snapshot.capture.count, 1)
        XCTAssertNil(history.snapshot.invalidity)
    }

    func testOwnerHistoryUsesSameAdmissionClockAndRetainsBoundedStages() throws {
        let owner = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 3)
        for i in 0..<5 {
            let pts = CMTime(value: Int64(i), timescale: 30)
            owner.observe(.captureVideo, sourcePTS: pts)
            owner.observe(.encodedVideo, sourcePTS: pts)
        }
        let history = try XCTUnwrap(owner.sourceHistorySnapshot)
        let ordinary = owner.snapshot
        XCTAssertEqual(history.scope, ordinary.scope)
        XCTAssertEqual(history.capture.map { $0.sourcePTS.value }, [2, 3, 4])
        XCTAssertEqual(history.encoded.count, 3)
        XCTAssertEqual(history.omittedCaptureFrames, 2)
        XCTAssertEqual(history.omittedEncodedFrames, 2)
        XCTAssertEqual(history.capture.last?.observedAt, ordinary.current.captureVideo.lastObservationTime)
        XCTAssertEqual(history.encoded.last?.observedAt, ordinary.current.encodedVideo.lastObservationTime)
        XCTAssertNil(history.invalidity)
    }

    func testOwnerHistoryIsOptInAndCloseFreezesItWithOrdinaryObservation() throws {
        XCTAssertNil(try VideoFrameObservationOwner(scope: scope).sourceHistorySnapshot)
        XCTAssertThrowsError(try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 0))
        let owner = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 8)
        owner.observe(.captureVideo, sourcePTS: .zero)
        _ = owner.close()
        owner.observe(.captureVideo, sourcePTS: CMTime(value: 1, timescale: 30))
        let history = try XCTUnwrap(owner.sourceHistorySnapshot)
        XCTAssertTrue(history.isClosed)
        XCTAssertEqual(history.capture.count, 1)
        XCTAssertEqual(owner.snapshot.current.captureVideo.callbackCount, 1)
    }

    func testOwnerHistoryQuarantineDoesNotStopOrdinaryCallbacks() throws {
        let owner = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 8)
        for value in [0, 0, 1] { XCTAssertTrue(owner.observe(.captureVideo, sourcePTS: CMTime(value: Int64(value), timescale: 30))) }
        let history = try XCTUnwrap(owner.sourceHistorySnapshot)
        XCTAssertEqual(history.invalidity, .sourceOrder)
        XCTAssertEqual(history.capture.count, 1)
        XCTAssertEqual(owner.snapshot.current.captureVideo.callbackCount, 3)
    }
}
