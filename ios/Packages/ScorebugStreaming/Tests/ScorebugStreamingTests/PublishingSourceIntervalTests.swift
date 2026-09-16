import CoreMedia
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class PublishingSourceIntervalTests: XCTestCase {
    private let relayOrigin: Int64 = 10_919
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 2,
              publishingAttemptID: UUID(), appliedProfileRevision: 1)
    }
    private func history(capacity: Int = 512, base: CMTime = .zero, count: Int = 301,
                         omitCapture: Set<Int> = [], omitEncoded: Set<Int> = []) throws -> VideoSourceHistory {
        var result = try VideoSourceHistory(scope: scope, capacity: capacity)
        for i in 0..<count {
            let pts = CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30))
            if !omitCapture.contains(i) { result.observe(.captureVideo, sourcePTS: pts, at: Double(i) / 30) }
            if !omitEncoded.contains(i) { result.observe(.encodedVideo, sourcePTS: pts, at: Double(i) / 30) }
        }
        return result
    }
    private func match(_ history: VideoSourceHistory, first: Int = 150, last: Int = 299,
                       previous: Int = 149, decoded: Int64 = 150,
                       origin: CMTime = .zero) throws -> PublishingSourceInterval? {
        PublishingSourceInterval.match(history: history.snapshot,
            clock: try XCTUnwrap(PublishingTransportClock(sourceOrigin: origin, publishingGeneration: 7)),
            relayOriginPTS: relayOrigin, previousDecodedPTS: Int64(previous) * 3000 + 9000 - relayOrigin,
            firstDecodedPTS: Int64(first) * 3000 + 9000 - relayOrigin,
            lastDecodedPTS: Int64(last) * 3000 + 9000 - relayOrigin, decodedFrames: decoded)
    }

    private func encodingHistory(_ values: [VideoEncodingObservation?]) throws -> VideoSourceHistory {
        var history = try VideoSourceHistory(scope: scope)
        for (i, value) in values.enumerated() {
            let pts = CMTime(value: Int64(i), timescale: 30)
            history.observe(.captureVideo, sourcePTS: pts, at: Double(i) + 1)
            history.observe(.encodedVideo, sourcePTS: pts, at: Double(i) + 1, encoding: value)
        }
        return history
    }
    private func encoding(_ configuration: VideoEncodingConfiguration?, session: UUID) throws -> VideoEncodingObservation {
        try XCTUnwrap(.init(encoderSessionID: session, configuration: configuration, submittedAt: 0, completedAt: 0))
    }
    func testVerifiedCoverageExcludesPriorAnchorConfiguration() throws {
        let session = UUID(), config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let old = try encoding(nil, session: session), new = try encoding(config, session: session)
        let h = try encodingHistory([old, old, old, new, new, new])
        XCTAssertEqual(try match(h, first: 3, last: 5, previous: 2, decoded: 3)?.encodingCoverage, .verified(config))
        XCTAssertEqual(try match(h, first: 2, last: 5, previous: 1, decoded: 4)?.encodingCoverage, .mixed)
    }
    func testLeadingMissingDecodedFramesStillParticipateInCoverage() throws {
        let session = UUID(), config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let old = try encoding(nil, session: session), new = try encoding(config, session: session)
        let h = try encodingHistory([old, old, old, new, new, new])
        let value = try XCTUnwrap(match(h, first: 3, last: 5, previous: 1, decoded: 3))
        XCTAssertEqual(value.encodedFrames, 4)
        XCTAssertEqual(value.leadingMissingEncodedFrames, 1)
        XCTAssertEqual(value.encodingCoverage, .mixed)
    }
    func testUnverifiedCoverageRequiresOneSessionAcrossAllIncludedFrames() throws {
        let a = try encoding(nil, session: UUID()), b = try encoding(nil, session: UUID())
        XCTAssertEqual(try match(encodingHistory([nil, a, a, a]), first: 1, last: 3, previous: 0, decoded: 3)?.encodingCoverage, .unverified)
        XCTAssertEqual(try match(encodingHistory([a, a, b, a]), first: 1, last: 3, previous: 0, decoded: 3)?.encodingCoverage, .mixed)
    }
    func testMissingMetadataPreservesCountsButCannotVerifyConfiguration() throws {
        let session = UUID(), config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let known = try encoding(config, session: session)
        for missing in 1...3 {
            var frames: [VideoEncodingObservation?] = [known, known, known, known]
            frames[missing] = nil
            let value = try XCTUnwrap(match(encodingHistory(frames), first: 1, last: 3, previous: 0, decoded: 3))
            XCTAssertEqual(value.encodedFrames, 3)
            XCTAssertEqual(value.encodingCoverage, .unavailable)
        }
    }
    func testSameBitrateDifferentWriteIDsAndSessionReplacementAreMixed() throws {
        let session = UUID()
        let a = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let b = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let other = UUID(), c = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: other, bitRate: 2_000_000))
        let first = try encoding(a, session: session)
        for value in [try encoding(b, session: session), try encoding(c, session: other)] {
            XCTAssertEqual(try match(encodingHistory([first, first, value, first]), first: 1, last: 3, previous: 0, decoded: 3)?.encodingCoverage, .mixed)
        }
    }
    func testMissingMetadataOverridesMixedAndInteriorLossCannotHideAConfiguration() throws {
        let session = UUID(), config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let old = try encoding(nil, session: session), new = try encoding(config, session: session)
        XCTAssertEqual(try match(encodingHistory([old, old, nil, new]), first: 1, last: 3, previous: 0, decoded: 3)?.encodingCoverage, .unavailable)
        let value = try XCTUnwrap(match(encodingHistory([new, new, old, new]), first: 1, last: 3, previous: 0, decoded: 2))
        XCTAssertEqual(value.encodedNotDecodedFrames, 1)
        XCTAssertEqual(value.encodingCoverage, .mixed)
    }

    func testClosedHistoryKeepsVerifiedCoverageHistorical() throws {
        let session = UUID(), config = try XCTUnwrap(VideoEncodingConfiguration(id: UUID(), encoderSessionID: session, bitRate: 2_000_000))
        let known = try encoding(config, session: session)
        var h = try encodingHistory([known, known, known, known]); h.close()
        XCTAssertEqual(try match(h, first: 1, last: 3, previous: 0, decoded: 3)?.encodingCoverage, .verified(config))
    }

    func testHealthyIntervalCountsSameSourceRangeAtEveryStage() throws {
        let history = try history()
        let result = try XCTUnwrap(match(history))
        XCTAssertEqual(result.scope, history.snapshot.scope)
        XCTAssertEqual(result.publishingGeneration, 7)
        XCTAssertEqual(result.relayOriginPTS, relayOrigin)
        XCTAssertEqual(CMTimeCompare(result.sourceStartExclusive, CMTime(value: 149, timescale: 30)), 0)
        XCTAssertEqual(CMTimeCompare(result.sourceEndInclusive, CMTime(value: 299, timescale: 30)), 0)
        XCTAssertEqual(result.captureBoundaryEndTime - result.captureBoundaryStartTime, 5, accuracy: 1e-10)
        XCTAssertEqual(result.capturedFrames, 150)
        XCTAssertEqual(result.encodedFrames, 150)
        XCTAssertEqual(result.decodedFrames, 150)
        XCTAssertEqual(result.captureNotEncodedFrames, 0)
        XCTAssertEqual(result.encodedNotDecodedFrames, 0)
    }

    func testLeadingLossBetweenWorkerWindowsRemainsInDenominator() throws {
        let result = try XCTUnwrap(match(history(), first: 155, decoded: 145))
        XCTAssertEqual(result.encodedFrames, 150)
        XCTAssertEqual(result.encodedNotDecodedFrames, 5)
        XCTAssertEqual(result.leadingMissingEncodedFrames, 5)
    }

    func testInteriorDecoderLossAndEncoderLossAreSeparate() throws {
        let history = try history(omitEncoded: Set(170..<180))
        let result = try XCTUnwrap(match(history, decoded: 135))
        XCTAssertEqual(result.capturedFrames, 150)
        XCTAssertEqual(result.encodedFrames, 140)
        XCTAssertEqual(result.captureNotEncodedFrames, 10)
        XCTAssertEqual(result.encodedNotDecodedFrames, 5)
        XCTAssertEqual(result.leadingMissingEncodedFrames, 0)
    }

    func testRationalOriginAndPreOriginCaptureUseExactSDKProjection() throws {
        let origin = CMTime(value: 493, timescale: 4)
        let shifted = try history(base: origin)
        XCTAssertEqual(try match(shifted, origin: origin)?.encodedFrames, 150)
        let preOrigin = try history(base: CMTime(value: -1, timescale: 30), count: 302)
        XCTAssertEqual(try match(preOrigin)?.encodedFrames, 150)
    }

    func testWireWrapAndNegativeDecoderCoordinates() throws {
        let base = CMTime(value: PublishingTransportClock.wireModulus - 15_000, timescale: 90_000)
        let history = try history(base: base, count: 8)
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        for shift in [Int64(0), PublishingTransportClock.wireModulus, -PublishingTransportClock.wireModulus] {
            let result = PublishingSourceInterval.match(history: history.snapshot, clock: clock,
                relayOriginPTS: 0, previousDecodedPTS: -3000 + shift,
                firstDecodedPTS: shift, lastDecodedPTS: 12_000 + shift, decodedFrames: 5)
            XCTAssertEqual(result?.encodedFrames, 5)
        }
    }

    func testMissingEvictedOrUnobservedBoundariesAreUnknown() throws {
        XCTAssertNil(try match(history(capacity: 100)))
        for missing in [149, 150, 299] {
            XCTAssertNil(try match(history(omitEncoded: [missing])))
        }
        XCTAssertNil(try match(history(omitCapture: [149])))
        XCTAssertNil(try match(history(omitCapture: [299])))
    }

    func testEncodedFrameWithoutMatchingCapturedPTSIsUnknownEvenWhenCountsPermitIt() throws {
        XCTAssertNil(try match(history(omitCapture: [190], omitEncoded: [191])))
    }

    func testInvalidDecodedCountsOrOrderingAreUnknown() throws {
        let h = try history()
        for count in [Int64(-1), 0, 1, 151, Int64.max] { XCTAssertNil(try match(h, decoded: count)) }
        XCTAssertNil(try match(h, first: 149))
        XCTAssertNil(try match(h, first: 300))
        XCTAssertNil(try match(h, last: 149))
        XCTAssertNil(try match(h, first: 155, decoded: 146))
        XCTAssertEqual(try match(h, first: 299, decoded: 1)?.leadingMissingEncodedFrames, 149)
    }

    func testWrongRelayOriginAndWholeWrapAmbiguityAreUnknown() throws {
        let h = try history()
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        for origin in [-1, PublishingTransportClock.wireModulus, relayOrigin + 1] {
            XCTAssertNil(PublishingSourceInterval.match(history: h.snapshot, clock: clock,
                relayOriginPTS: origin, previousDecodedPTS: 149 * 3000 + 9000 - relayOrigin,
                firstDecodedPTS: 150 * 3000 + 9000 - relayOrigin,
                lastDecodedPTS: 299 * 3000 + 9000 - relayOrigin, decodedFrames: 150))
        }
        XCTAssertNil(PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: relayOrigin, previousDecodedPTS: 149 * 3000 + 9000 - relayOrigin,
            firstDecodedPTS: 150 * 3000 + 9000 - relayOrigin,
            lastDecodedPTS: 299 * 3000 + 9000 - relayOrigin + PublishingTransportClock.wireModulus,
            decodedFrames: 150))
    }

    func testQuarantinedHistoryAndProjectionCollisionsAreUnknown() throws {
        var h = try history()
        h.observe(.captureVideo, sourcePTS: .invalid, at: 11)
        XCTAssertNil(try match(h))
        var collision = try VideoSourceHistory(scope: scope)
        for i in 0..<4 {
            let pts = CMTime(value: Int64(i), timescale: 180_000)
            collision.observe(.captureVideo, sourcePTS: pts, at: Double(i))
            collision.observe(.encodedVideo, sourcePTS: pts, at: Double(i))
        }
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        XCTAssertNil(PublishingSourceInterval.match(history: collision.snapshot, clock: clock,
            relayOriginPTS: 0, previousDecodedPTS: 9000, firstDecodedPTS: 9001, lastDecodedPTS: 9001, decodedFrames: 1))
    }

    func testClosedHistoryRemainsHistoricalEvidence() throws {
        var h = try history()
        h.close()
        XCTAssertEqual(try match(h)?.encodedFrames, 150)
    }

    func testUnevenTickQuantizationPreservesExactRationalInterval() throws {
        var h = try VideoSourceHistory(scope: scope, capacity: 512)
        for i in 0...300 {
            let pts = CMTime(value: 29 + Int64(i) * 7, timescale: 203) // 1/7 + i/29
            h.observe(.captureVideo, sourcePTS: pts, at: Double(i) / 29)
            h.observe(.encodedVideo, sourcePTS: pts, at: Double(i) / 29)
        }
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: CMTime(value: 1, timescale: 7), publishingGeneration: 1))
        // Independent integer oracle; no SDK projector is used by the test.
        func decoder(_ frame: Int64) -> Int64 { frame * 90_000 / 29 + 9000 - relayOrigin }
        let result = PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: relayOrigin, previousDecodedPTS: decoder(149),
            firstDecodedPTS: decoder(150), lastDecodedPTS: decoder(299), decodedFrames: 150)
        XCTAssertEqual(result?.capturedFrames, 150)
        XCTAssertEqual(result?.encodedNotDecodedFrames, 0)
    }

    func testExtremeSourceOriginAndProjectionOverflowDoNotTrapOrRoundThroughDouble() throws {
        var h = try VideoSourceHistory(scope: scope)
        for i in 0...2 {
            let pts = CMTime(value: Int64.min + Int64(i), timescale: 1)
            h.observe(.captureVideo, sourcePTS: pts, at: Double(i))
            h.observe(.encodedVideo, sourcePTS: pts, at: Double(i))
        }
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: CMTime(value: Int64.min, timescale: 1), publishingGeneration: 1))
        let result = PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: 0, previousDecodedPTS: 99_000,
            firstDecodedPTS: 189_000, lastDecodedPTS: 189_000, decodedFrames: 1)
        XCTAssertEqual(result?.encodedFrames, 1)
        XCTAssertEqual(result?.sourceEndInclusive.value, Int64.min + 2)
        h.observe(.captureVideo, sourcePTS: CMTime(value: .max, timescale: 1), at: 3)
        XCTAssertNil(PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: 0, previousDecodedPTS: 99_000,
            firstDecodedPTS: 189_000, lastDecodedPTS: 189_000, decodedFrames: 1))
    }

    func testAmbiguousRetainedHistoryAndOverflowingDecoderSpanAreUnknown() throws {
        var h = try VideoSourceHistory(scope: scope)
        let half = PublishingTransportClock.wireModulus / 2
        for (index, value) in [Int64(0), half, half + 3000, half + 6000].enumerated() {
            let pts = CMTime(value: value, timescale: 90_000)
            h.observe(.captureVideo, sourcePTS: pts, at: Double(index))
            h.observe(.encodedVideo, sourcePTS: pts, at: Double(index))
        }
        let clock = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        XCTAssertNil(PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: 0, previousDecodedPTS: half + 9000,
            firstDecodedPTS: half + 12_000, lastDecodedPTS: half + 15_000, decodedFrames: 2))
        XCTAssertNil(PublishingSourceInterval.match(history: h.snapshot, clock: clock,
            relayOriginPTS: 0, previousDecodedPTS: .min,
            firstDecodedPTS: 0, lastDecodedPTS: .max, decodedFrames: 2))
    }
}
