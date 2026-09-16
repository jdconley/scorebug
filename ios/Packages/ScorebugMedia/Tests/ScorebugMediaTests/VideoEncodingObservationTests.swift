import CoreMedia
import XCTest
@testable import ScorebugMedia

final class VideoEncodingObservationTests: XCTestCase {
    private let session = UUID()
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
              publishingAttemptID: UUID(), appliedProfileRevision: 1)
    }
    private func configuration() throws -> VideoEncodingConfiguration {
        try XCTUnwrap(.init(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
    }
    private func observation(_ configuration: VideoEncodingConfiguration? = nil, submitted: Double = 1, completed: Double = 2) throws -> VideoEncodingObservation {
        try XCTUnwrap(.init(encoderSessionID: session, configuration: configuration, submittedAt: submitted, completedAt: completed))
    }
    func testConfigurationRejectsInvalidRateAndSupportsWatchIntegerBounds() {
        for rate in [-1, 0, Int(Int32.max) + 1, Int.max] {
            XCTAssertNil(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: rate))
        }
        XCTAssertNotNil(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: Int(Int32.max)))
    }
    func testObservationRejectsMismatchedSessionAndInvalidTimes() throws {
        let configuration = try configuration()
        XCTAssertNil(VideoEncodingObservation(encoderSessionID: UUID(), configuration: configuration, submittedAt: 1, completedAt: 2))
        for (start, end) in [(-1.0, 2.0), (2, 1), (.nan, 2), (1, .nan), (.infinity, .infinity), (1, .infinity)] {
            XCTAssertNil(VideoEncodingObservation(encoderSessionID: session, configuration: nil, submittedAt: start, completedAt: end))
        }
        XCTAssertNotNil(VideoEncodingObservation(encoderSessionID: session, configuration: configuration, submittedAt: 1, completedAt: 1))
    }
    func testHistoryRetainsMetadataOnlyForEncodedFramesAdmittedAfterCompletion() throws {
        var history = try VideoSourceHistory(scope: scope)
        let value = try observation(configuration())
        history.observe(.captureVideo, sourcePTS: .zero, at: 2, encoding: value)
        history.observe(.encodedVideo, sourcePTS: .zero, at: 2, encoding: value)
        XCTAssertNil(history.snapshot.capture[0].encoding)
        XCTAssertEqual(history.snapshot.encoded[0].encoding, value)
        history.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30), at: 3,
                        encoding: try observation(completed: 4))
        XCTAssertNil(history.snapshot.encoded[1].encoding)
        XCTAssertNil(history.snapshot.invalidity)
        XCTAssertEqual(history.snapshot.encoded.count, 2)
    }
    func testMetadataEvictionAndClosePreserveBoundedImmutableHistory() throws {
        var history = try VideoSourceHistory(scope: scope, capacity: 2)
        let first = try observation(configuration()), second = try observation(configuration())
        for (index, value) in [first, second, first].enumerated() {
            history.observe(.encodedVideo, sourcePTS: CMTime(value: Int64(index), timescale: 30), at: 3, encoding: value)
        }
        let snapshot = history.snapshot
        XCTAssertEqual(snapshot.encoded.map(\.encoding), [second, first])
        XCTAssertEqual(snapshot.omittedEncodedFrames, 1)
        history.close()
        XCTAssertFalse(history.observe(.encodedVideo, sourcePTS: CMTime(value: 3, timescale: 30), at: 4, encoding: second))
        XCTAssertEqual(history.snapshot.encoded.map(\.encoding), snapshot.encoded.map(\.encoding))
    }
    func testOwnerRecordsConfigurationAndAggregateExactlyOnce() throws {
        let owner = try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 2)
        let value = try observation(configuration())
        XCTAssertTrue(owner.observe(.encodedVideo, sourcePTS: .zero, encoding: value))
        let history = try XCTUnwrap(owner.sourceHistorySnapshot)
        XCTAssertEqual(history.encoded.first?.encoding, value)
        XCTAssertEqual(owner.snapshot.current.encodedVideo.callbackCount, 1)
        _ = owner.close()
        XCTAssertFalse(owner.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30), encoding: value))
        XCTAssertEqual(owner.sourceHistorySnapshot?.encoded.count, 1)
    }
}
