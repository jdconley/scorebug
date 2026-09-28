import AVFoundation
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

    @MainActor
    func testUHDSourceCanMeasure360WithoutRejectingRawFrames() async throws {
        let candidate = try PublishingCandidateEncoder(scope: scope(), profile: .low360)
        try await candidate.start()
        for n in 0..<12 {
            let accepted = candidate.offer(try sample(pts: CMTime(value: Int64(n), timescale: 30),
                width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
            if !accepted { break }
            try await Task.sleep(for: .milliseconds(34))
        }
        let result = await candidate.finish()
        XCTAssertEqual(result.encoding.outcome, .completed, result.encoding.failure ?? "")
        XCTAssertEqual(result.encoding.acceptedInputCount, 12, result.encoding.failure ?? "")
        XCTAssertEqual(result.encoding.outputCount, 12, result.encoding.failure ?? "")
    }

    @MainActor
    func test720RecipeProducesActualVideoToolboxH264At720Dimensions() async throws {
        let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "720p30"))
        let scope = scope()
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: profile)
        do {
            try await candidate.start()
            for n in 0..<3 {
                XCTAssertTrue(candidate.offer(try sample(pts: CMTime(value: Int64(n), timescale: 30))))
            }
            let result = await candidate.finish()
            XCTAssertEqual(result.profile, profile)
            XCTAssertEqual(result.scope, scope)
            XCTAssertEqual(result.encoding.outcome, .completed, result.encoding.failure ?? "")
            XCTAssertEqual(result.encoding.acceptedInputCount, 3)
            XCTAssertEqual(result.encoding.outputCount, 3)
            XCTAssertEqual(result.encoding.frames.count, 3)
            XCTAssertNotNil(result.encoding.encoderSessionID)
            XCTAssertEqual(result.encoding.frames.first?.isSync, true)
            for frame in result.encoding.frames {
                XCTAssertEqual(frame.width, 1280); XCTAssertEqual(frame.height, 720)
                XCTAssertGreaterThan(frame.byteCount, 0)
                XCTAssertEqual(frame.encoderSessionID, result.encoding.encoderSessionID)
            }
            // finish() joins the native session; a repeated join is terminal.
            let joined = await candidate.finish()
            XCTAssertEqual(joined.encoding.outputCount, 3)
            XCTAssertEqual(joined.encoding.outcome, .completed)
        } catch { _ = await candidate.cancel(); throw error }
    }

    @MainActor
    func testOptionalTransportJoinsActualCandidateVideoWithCopiedLiveAAC() async throws {
        let scope = scope(), transport = PublishingCandidateTransport(scope: scope, profile: .low240)
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low240, transport: transport)
        XCTAssertTrue(transport.arm(publishingGeneration: 7))
        try await candidate.start()
        do {
            for index in 0..<3 {
                XCTAssertTrue(candidate.offer(try sample(pts: CMTime(value: 300 + Int64(index), timescale: 30))))
            }
            for index in 0...4 {
                let host = AVAudioTime.hostTime(forSeconds: 10 + Double(index) * 1024 / 48000)
                transport.observeAudio(PublishingCandidateTransport.AudioSnapshot(
                    sourcePTS: CMTime(seconds: AVAudioTime.seconds(forHostTime: host), preferredTimescale: 1_000_000_000),
                    hostTime: host, publishingGeneration: 7, wasEncoded: true, valid: true,
                    observedAt: ProcessInfo.processInfo.systemUptime, sampleRate: 48000, channelCount: 2,
                    framesPerPacket: 1024, audioObjectType: 2, payload: Data(repeating: 42, count: 4)))
            }
            let result = await candidate.finish()
            XCTAssertEqual(result.encoding.outcome, .completed, result.encoding.failure ?? "")
            let measured = try XCTUnwrap(result.transport)
            XCTAssertEqual(measured.outcome, .completed, measured.failure ?? "")
            XCTAssertEqual(measured.id, candidate.id)
            XCTAssertEqual(measured.mux?.videoInputCount, 3)
            XCTAssertEqual(measured.mux?.audioInputCount, 4)
            XCTAssertEqual(measured.mux?.videoInputBytes, result.encoding.frames.reduce(0) { $0 + $1.byteCount })
        } catch { _ = await candidate.cancel(); throw error }
    }

    @MainActor
    func testOptionalTransportFailsClosedOnRawRejectionAndCancellation() async throws {
        for reject in [false, true] {
            let scope = scope(), transport = PublishingCandidateTransport(scope: scope, profile: .low240)
            let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low240, transport: transport)
            XCTAssertTrue(transport.arm(publishingGeneration: 7)); try await candidate.start()
            if reject { XCTAssertFalse(candidate.offer(try sample(pts: .invalid))) }
            let result = reject ? await candidate.finish() : await candidate.cancel()
            XCTAssertNotNil(result.transport)
            XCTAssertNotEqual(result.transport?.outcome, .completed)
            XCTAssertNotEqual(result.encoding.outcome, .completed)
        }
    }

    @MainActor
    func testPreCancelledAdapterFinishJoinsNativeAndRevokesEnabledAudioWindow() async throws {
        let scope = scope(), transport = PublishingCandidateTransport(scope: scope, profile: .low240)
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low240, transport: transport)
        XCTAssertTrue(transport.arm(publishingGeneration: 7))
        try await candidate.start()
        do {
            XCTAssertTrue(candidate.offer(try sample(pts: CMTime(value: 10, timescale: 1))))
            // MainActor ensures this task starts only after cancellation. This
            // verifies the joined public result, not native-blocked revocation
            // timing (the adapter deliberately exposes no native session hook).
            let finishing = Task { await candidate.finish() }
            finishing.cancel()
            let result = await finishing.value
            XCTAssertEqual(result.encoding.outcome, .cancelled)
            XCTAssertEqual(result.transport?.outcome, .cancelled)
            XCTAssertEqual(result.encoding.acceptedInputCount, 1)
            let repeated = await candidate.finish()
            XCTAssertEqual(repeated.encoding.outcome, .cancelled)
            XCTAssertEqual(repeated.encoding.outputCount, result.encoding.outputCount)
            XCTAssertEqual(repeated.transport?.endedAt, result.transport?.endedAt)
            XCTAssertFalse(candidate.offer(try sample(pts: CMTime(value: 301, timescale: 30))))
        } catch { _ = await candidate.cancel(); throw error }
    }

    private func sample(pts: CMTime, width: Int = 64, height: Int = 64, pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
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
