@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import ScorebugStreaming
import VideoToolbox
import XCTest
@testable import HaishinKit

/// A finite diagnostic, deliberately outside the production candidate owner.
/// Cumulative raw payload is bounded even if no native output arrives.
final class EncoderBufferDepthTests: XCTestCase {
    @MainActor func testDefaultCandidateBufferDepth() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Buffer-depth qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        let scope = VideoFrameObservationScope(recordingID: "diagnostic", matchID: "diagnostic", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let settings = try PublishingCandidateEncoder(scope: scope, profile: .low360).requestedSettings
        var runs: [[String: Any]] = []
        for (name, count) in [("default4", 4), ("default8", 8), ("default16", 16), ("default20", 20), ("defaultRepeat4", 4)] {
            runs.append(await measure(name: name, count: count, profile: profile, motion: motion, settings: settings))
        }
        let report: [String: Any] = ["formatVersion": 1, "experiment": "candidate-buffer-depth", "platform": "iOS Simulator",
            "workload": "motion-blocks16", "inputWidth": 1920, "inputHeight": 1080, "profile": "360p30", "firstSourceFrame": 758,
            "rawByteBudget": 64 * 1024 * 1024, "allocationReservation": 4 * 1024 * 1024, "runs": runs]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 512 * 1024)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderBufferDepth"; attachment.lifetime = .keepAlways; add(attachment)
        for run in runs {
            XCTAssertEqual(run["errors"] as? [String], [], run["name"] as? String ?? "")
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual((run["inputs"] as? [[String: Any]])?.count, run["count"] as? Int)
            XCTAssertEqual((run["frames"] as? [[String: Any]])?.count, run["count"] as? Int)
        }
    }

    @MainActor private func measure(name: String, count: Int, profile: ArchiveProfile,
                                    motion: FixtureMotionPattern, settings: VideoCodecSettings) async -> [String: Any] {
        let evidence = BufferDepthEvidence(count: count)
        let started = ProcessInfo.processInfo.systemUptime
        let codec = VideoCodec(encoderConfigurationObserver: { evidence.observe($0) })
        codec.settings = settings
        let output = codec.outputStream
        codec.startRunning()
        // Output consumption cannot be blocked by synchronous native append or drain.
        let consumer = Task.detached {
            for await sample in output { autoreleasepool { evidence.deliver(sample) } }
        }
        var inputs: [[String: Any]] = [], allocated = 0
        let reservation = 4 * 1024 * 1024, budget = 64 * 1024 * 1024
        do {
            let origin = CMTime(value: 7395, timescale: 60)
            let began = ContinuousClock.now
            var previousReturn = began - .seconds(1)
            for index in 0..<count {
                try Task.checkCancellation()
                guard allocated <= budget - reservation else { throw DepthError.rawBudget }
                let sample = try autoreleasepool {
                    try FixtureCameraSource.video(frame: 758 + index, profile: profile, origin: origin, motion: motion)
                }
                guard let pixel = sample.imageBuffer else { throw DepthError.rawBuffer }
                let rawBytes = CVPixelBufferGetDataSize(pixel)
                guard rawBytes > 0, rawBytes <= reservation else { throw DepthError.rawBuffer }
                allocated += rawBytes
                let deadline = max(began + .seconds(Double(index) / 30), previousReturn + .seconds(1.0 / 60))
                try await ContinuousClock().sleep(until: deadline)
                let offered = ProcessInfo.processInfo.systemUptime
                guard offered >= started, offered - started < 8 else { throw DepthError.admissionDeadline }
                codec.append(sample)
                let returned = ProcessInfo.processInfo.systemUptime
                previousReturn = ContinuousClock.now
                guard let receipt = codec.lastSubmission,
                      CMTimeCompare(receipt.sourcePTS, sample.presentationTimeStamp) == 0 else { throw DepthError.submission }
                inputs.append(["frame": 758 + index, "offeredAt": offered, "returnedAt": returned, "rawBytes": rawBytes,
                    "encoderSessionID": receipt.sessionID.uuidString, "sourcePTS": depthTime(receipt.sourcePTS)])
                guard codec.failure.error == nil else { throw DepthError.nativeFailure }
                guard returned - started < 8 else { throw DepthError.admissionDeadline }
            }
            // The idle interval begins after all synchronous native submissions return.
            try await Task.sleep(for: .seconds(1))
        } catch { evidence.reject(String(describing: error)) }
        let checkpoint = evidence.checkpoint()
        if checkpoint.at - started >= 8 { evidence.reject("admissionDeadline") }
        let completion = codec.makeCompletion()
        await Task.detached(priority: .utility) { completion() }.value
        await consumer.value
        let nativeFailure = codec.failure.error.map { String(describing: $0) }
        codec.stopRunning()
        let ended = ProcessInfo.processInfo.systemUptime
        var result = evidence.report()
        result.merge(["name": name, "id": UUID().uuidString, "count": count, "startedAt": started,
            "beforeFinishAt": checkpoint.at, "beforeFinishOutputs": checkpoint.outputs, "endedAt": ended,
            "rawBytesAllocated": allocated, "nativeFailure": nativeFailure as Any? ?? NSNull(), "inputs": inputs,
            "requested": ["width": settings.videoSize.width, "height": settings.videoSize.height, "bitRate": settings.bitRate,
                "profileLevel": settings.profileLevel, "expectedFrameRate": settings.expectedFrameRate as Any? ?? NSNull(),
                "maxKeyFrameIntervalDuration": settings.maxKeyFrameIntervalDuration,
                "allowFrameReordering": settings.allowFrameReordering as Any? ?? NSNull()]]) { _, new in new }
        return result
    }
    private enum DepthError: Error { case rawBudget, rawBuffer, admissionDeadline, submission, nativeFailure }
}

private func depthTime(_ value: CMTime) -> [String: Any] {
    ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
}

/// Bounded scalar joins only: no sample or image is retained by this recorder.
private final class BufferDepthEvidence: @unchecked Sendable {
    private struct Output {
        let pts: CMTime, dequeuedAt: Double, bytes: Int, width: Int32, height: Int32, sync: Bool
    }
    private let lock = NSLock()
    private let count: Int
    private var callbacks: [Int: VideoEncoderFrame] = [:]
    private var outputs: [Int: Output] = [:]
    private var errors: [String] = []
    init(count: Int) { self.count = count }
    private func frameID(_ time: CMTime) -> Int? {
        guard time.isNumeric, time.epoch == 0 else { return nil }
        let delta = time - CMTime(value: 7395, timescale: 60)
        let scaled = CMTimeConvertScale(delta, timescale: 30, method: .default)
        guard scaled.isNumeric, scaled.value >= 758, scaled.value < 758 + count,
              CMTimeCompare(scaled, delta) == 0 else { return nil }
        return Int(scaled.value)
    }
    private func fail(_ reason: String) { if errors.count < 8 { errors.append(reason) } }
    func reject(_ reason: String) { lock.withLock { fail(reason) } }
    func observe(_ frame: VideoEncoderFrame) {
        lock.withLock {
            guard let id = frameID(frame.sourcePTS), callbacks[id] == nil, callbacks.count < count,
                  CMTimeCompare(frame.sourcePTS, frame.outputPTS) == 0 else { fail("invalidCallback"); return }
            callbacks[id] = frame
        }
    }
    func deliver(_ sample: CMSampleBuffer) {
        lock.withLock {
            let at = ProcessInfo.processInfo.systemUptime
            guard let id = frameID(sample.presentationTimeStamp), outputs[id] == nil, outputs.count < count,
                  CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  sample.imageBuffer == nil, let format = sample.formatDescription,
                  format.mediaType == .video, format.isCompressed,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
                  let data = sample.dataBuffer, data.dataLength > 0, data.dataLength <= 2 * 1024 * 1024,
                  CMSampleBufferGetTotalSampleSize(sample) == data.dataLength else { fail("invalidOutput"); return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width == 640, dimensions.height == 360 else { fail("outputDimensions"); return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String]
            guard notSync == nil || notSync is Bool else { fail("invalidSyncMetadata"); return }
            let sync = !(notSync as? Bool ?? false)
            guard id != 758 || sync else { fail("missingInitialKeyframe"); return }
            outputs[id] = Output(pts: sample.presentationTimeStamp, dequeuedAt: at, bytes: data.dataLength,
                                 width: dimensions.width, height: dimensions.height, sync: sync)
        }
    }
    func checkpoint() -> (at: Double, outputs: Int) {
        lock.withLock { (ProcessInfo.processInfo.systemUptime, outputs.count) }
    }
    func report() -> [String: Any] {
        lock.withLock {
            if callbacks.count != count || outputs.count != count { fail("incompleteJoin") }
            let rows: [[String: Any]] = callbacks.keys.sorted().compactMap { id in
                guard let callback = callbacks[id], let output = outputs[id],
                      CMTimeCompare(callback.outputPTS, output.pts) == 0 else { fail("missingOutputJoin"); return nil }
                return ["frame": id, "sourcePTS": depthTime(callback.sourcePTS), "outputPTS": depthTime(output.pts),
                    "encoderSessionID": callback.encoderSessionID.uuidString, "submittedAt": callback.submittedAt,
                    "completedAt": callback.completedAt, "dequeuedAt": output.dequeuedAt,
                    "byteCount": output.bytes, "width": output.width, "height": output.height, "isSync": output.sync]
            }
            return ["frames": rows, "errors": errors]
        }
    }
}
