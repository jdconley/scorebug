import CoreMedia
import CoreVideo
import Foundation
import HaishinKit
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class PublishingCandidateEncoderTests: XCTestCase {
    private func scope() -> VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 7,
              publishingAttemptID: UUID(), appliedProfileRevision: 11)
    }

    func testCandidateUsesExactPublishingRecipeAndPreservesScope() throws {
        let scope = scope()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for profile in PublishingVideoProfile.allCases {
            let candidate = try PublishingCandidateEncoder(scope: scope, profile: profile)
            XCTAssertEqual(candidate.scope, scope)
            XCTAssertEqual(candidate.profile, profile)
            XCTAssertEqual(try encoder.encode(candidate.requestedSettings), try encoder.encode(profile.settings))
        }
    }

    func testEachMeasurementGetsFreshIdentityEvenWithinSameAttempt() throws {
        let scope = scope()
        let first = try PublishingCandidateEncoder(scope: scope, profile: .sd540)
        let second = try PublishingCandidateEncoder(scope: scope, profile: .sd540)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.scope, second.scope)
    }

    @MainActor
    func testCancellationPreservesRequestAndRemainsTerminal() async throws {
        let scope = scope()
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low360)
        try await candidate.start()
        let result = await candidate.cancel()
        XCTAssertEqual(result.scope, scope)
        XCTAssertEqual(result.profile, .low360)
        XCTAssertEqual(result.encoding.id, candidate.id)
        XCTAssertEqual(result.encoding.outcome, .cancelled)
        XCTAssertEqual(result.encoding.acceptedInputCount, 0)
        XCTAssertTrue(result.encoding.frames.isEmpty)
        let finished = await candidate.finish()
        XCTAssertEqual(finished.encoding.outcome, .cancelled)
        XCTAssertEqual(finished.encoding.id, result.encoding.id)
        XCTAssertFalse(candidate.offer(try sample(pts: .zero)))
    }

    @MainActor
    func testOfferFailureIsRetainedWithoutInventedMeasuredCost() async throws {
        let candidate = try PublishingCandidateEncoder(scope: scope(), profile: .hd1080)
        try await candidate.start()
        XCTAssertFalse(candidate.offer(try sample(pts: .invalid)))
        let result = await candidate.finish()
        XCTAssertEqual(result.profile, .hd1080)
        XCTAssertEqual(result.encoding.outcome, .failed)
        XCTAssertNotNil(result.encoding.failure)
        XCTAssertEqual(result.encoding.outputCount, 0)
        XCTAssertTrue(result.encoding.frames.isEmpty)
    }

    @MainActor
    func testEmptyFinishCannotClaimSuccessfulMeasurement() async throws {
        let candidate = try PublishingCandidateEncoder(scope: scope(), profile: .low240)
        try await candidate.start()
        let result = await candidate.finish()
        XCTAssertEqual(result.encoding.outcome, .failed)
        XCTAssertTrue(result.encoding.frames.isEmpty)
    }

    @MainActor
    func testPublishingRecipeProducesMeasuredH264AtCandidateDimensions() async throws {
        let scope = scope()
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low240)
        try await candidate.start()
        for n in 0..<3 {
            XCTAssertTrue(candidate.offer(try sample(pts: CMTime(value: Int64(n), timescale: 30))))
        }
        let result = await candidate.finish()
        XCTAssertEqual(result.scope, scope)
        XCTAssertEqual(result.encoding.outcome, .completed, result.encoding.failure ?? "")
        XCTAssertEqual(result.encoding.acceptedInputCount, 3)
        XCTAssertEqual(result.encoding.outputCount, 3)
        XCTAssertEqual(result.encoding.frames.count, 3)
        XCTAssertEqual(result.encoding.frames.first?.isSync, true)
        XCTAssertNotNil(result.encoding.encoderSessionID)
        for frame in result.encoding.frames {
            XCTAssertEqual(frame.width, 426)
            XCTAssertEqual(frame.height, 240)
            XCTAssertGreaterThan(frame.byteCount, 0)
            XCTAssertEqual(frame.encoderSessionID, result.encoding.encoderSessionID)
        }
    }

    private func sample(pts: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let address = CVPixelBufferGetBaseAddress(image) { memset(address, 0, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
