@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import VideoToolbox
import XCTest
@testable import HaishinKit

/// Existing settings replacement path; no network or production policy is changed.
final class EncoderResolutionTransitionTests: XCTestCase {
    @MainActor func testPacedResolutionTransitions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Resolution transition qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        let recorder = ResolutionTransitionRecorder()
        let codec = VideoCodec(encoderConfigurationObserver: recorder.observe)
        let output = codec.outputStream
        let consumer = Task.detached { for await sample in output { recorder.deliver(sample) } }
        var phases: [[String: Any]] = []
        var failure: String?
        var anchor = ProcessInfo.processInfo.systemUptime
        var began = ContinuousClock.now
        var lastAppendFinished = began
        var previousSession: VTCompressionSession?
        codec.startRunning()
        do {
            let origin = CMTime(value: 7395, timescale: 60)
            for frame in 0..<1800 {
                let phase = frame / 600, inputFrame = frame % 600
                let inputOrigin = origin + CMTime(value: Int64(frame - inputFrame), timescale: 30)
                let sample = try autoreleasepool {
                    try FixtureCameraSource.video(frame: inputFrame, profile: profile, origin: inputOrigin, motion: motion)
                }
                if frame > 0 {
                    let deadline = max(began + .seconds(Double(frame) / 30), lastAppendFinished + .seconds(1.0 / 60))
                    try await ContinuousClock().sleep(until: deadline)
                }
                let width = phase == 1 ? 960 : 1920, height = phase == 1 ? 540 : 1080
                let bitRate = phase == 1 ? 1_500_000 : 6_000_000
                let requestedAt = ProcessInfo.processInfo.systemUptime
                if inputFrame == 0 {
                    codec.settings = VideoCodecSettings(videoSize: CGSize(width: width, height: height),
                        bitRate: bitRate, profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
                        maxKeyFrameIntervalDuration: 2, allowFrameReordering: false, expectedFrameRate: 30)
                }
                let appendBeganAt = ProcessInfo.processInfo.systemUptime
                codec.append(sample)
                let appendEndedAt = ProcessInfo.processInfo.systemUptime
                lastAppendFinished = ContinuousClock.now
                if codec.failure.error != nil { throw ProbeFailure.codec }
                if inputFrame == 0 {
                    guard let rawSession = codec.session else { throw ProbeFailure.session }
                    let session = rawSession as! VTCompressionSession
                    let replaced = previousSession.map { ObjectIdentifier($0) != ObjectIdentifier(session) } ?? true
                    let native = try NativeEncoderSnapshot.capture(session)
                    phases.append(["firstFrame": frame, "frameCount": 600, "width": width, "height": height,
                        "bitRate": bitRate, "requestedAt": requestedAt, "appendBeganAt": appendBeganAt,
                        "appendEndedAt": appendEndedAt, "sessionReplaced": replaced, "native": native])
                    previousSession = session
                }
                if frame == 0 {
                    // Initial session creation is outside pacing; live replacements are inside it.
                    anchor = ProcessInfo.processInfo.systemUptime; began = ContinuousClock.now
                    lastAppendFinished = began
                }
            }
        } catch { failure = String(describing: error) }
        let complete = codec.makeCompletion()
        await Task.detached { complete() }.value
        if let error = codec.failure.error { failure = String(describing: error) }
        codec.stopRunning()
        await consumer.value
        var report = recorder.report()
        let frames = report["frames"] as! [[String: Any]]
        // Each snapshot was captured immediately after this exact first append,
        // without another codec mutation. Join its callback identity after drain.
        for i in phases.indices {
            let first = phases[i]["firstFrame"] as! Int
            var native = phases[i]["native"] as! [String: Any]
            native["encoderSessionID"] = frames.first { $0["frame"] as? Int == first }?["encoderSessionID"] ?? NSNull()
            phases[i]["native"] = native
        }
        report["formatVersion"] = 7; report["experiment"] = "live-resolution-transitions"
        report["platform"] = "iOS Simulator"; report["workload"] = "motion-blocks16"
        report["width"] = profile.width; report["height"] = profile.height
        report["framesPerSecond"] = 30; report["phaseFrames"] = 600; report["settlingFrames"] = 150
        report["pacingAnchor"] = anchor; report["phases"] = phases
        report["nativeFailure"] = failure.map { $0 as Any } ?? NSNull()
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderResolutionTransition"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNil(failure)
        XCTAssertEqual(report["errors"] as? [String], [])
        XCTAssertEqual(frames.count, 1800)
    }
    private enum ProbeFailure: Error { case codec, session }
}

/// Constant frame limit, bounded errors, scalar metadata only. Media is inspected
/// synchronously on delivery and released before the consumer requests more.
private final class ResolutionTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Int: VideoEncoderFrame] = [:]
    private var outputs: [Int: [String: Any]] = [:]
    private var errors: [String] = []
    private static func frameID(_ time: CMTime) -> Int? {
        guard time.isNumeric, time.epoch == 0 else { return nil }
        let delta = time - CMTime(value: 7395, timescale: 60)
        let scaled = CMTimeConvertScale(delta, timescale: 30, method: .default)
        guard scaled.isNumeric, scaled.value >= 0, scaled.value < 1800,
              CMTimeCompare(scaled, delta) == 0 else { return nil }
        return Int(scaled.value)
    }
    private func reject(_ reason: String) { if errors.count < 8 { errors.append(reason) } }
    func observe(_ frame: VideoEncoderFrame) {
        lock.withLock {
            guard let index = Self.frameID(frame.sourcePTS), observations[index] == nil,
                  observations.count < 1800 else { reject("invalid/duplicate callback"); return }
            observations[index] = frame
        }
    }
    func deliver(_ sample: CMSampleBuffer) {
        let at = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            let bytes = CMSampleBufferGetTotalSampleSize(sample)
            guard let index = Self.frameID(sample.presentationTimeStamp), outputs[index] == nil, outputs.count < 1800,
                  CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  sample.imageBuffer == nil, bytes > 0, bytes <= 2 * 1024 * 1024,
                  let block = sample.dataBuffer, let format = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
                reject("invalid/duplicate compressed output"); return
            }
            var parameterCount = 0, headerLength: Int32 = 0
            var parameterTypes: [Int] = []
            for parameterIndex in 0..<2 {
                var pointer: UnsafePointer<UInt8>?, size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: parameterIndex,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &headerLength)
                guard status == noErr, let pointer, size > 0, size <= 65536, parameterCount == 2 else {
                    reject("invalid parameter sets"); return
                }
                parameterTypes.append(Int(pointer.pointee & 0x1f))
            }
            guard headerLength == 4, CMBlockBufferGetDataLength(block) == bytes else { reject("invalid NAL layout"); return }
            var data = Data(count: bytes)
            let copied = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
            }
            guard copied == noErr else { reject("unreadable NAL data"); return }
            var offset = 0, hasIDR = false
            while offset < bytes {
                guard bytes - offset >= 4 else { reject("truncated NAL length"); return }
                let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
                offset += 4
                guard length > 0, length <= bytes - offset else { reject("invalid NAL length"); return }
                if data[offset] & 0x1f == 5 { hasIDR = true }
                offset += length
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? NSNumber)?.boolValue ?? false
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            outputs[index] = ["bytes": bytes, "deliveredAt": at, "deliveryOrdinal": outputs.count,
                "outputPTS": Self.time(sample.presentationTimeStamp), "encodedWidth": dimensions.width,
                "encodedHeight": dimensions.height, "isSync": !notSync, "hasIDR": hasIDR,
                "parameterSetTypes": parameterTypes, "nalUnitHeaderLength": headerLength]
        }
    }
    private static func time(_ t: CMTime) -> [String: Any] {
        ["value": String(t.value), "timescale": t.timescale, "epoch": String(t.epoch), "flags": t.flags.rawValue]
    }
    func report() -> [String: Any] {
        lock.withLock {
            if observations.count != 1800 || outputs.count != 1800 { reject("incomplete frame join") }
            let rows: [[String: Any]] = observations.keys.sorted().compactMap { index in
                guard let frame = observations[index], var output = outputs[index] else { return nil }
                guard Self.frameID(frame.outputPTS) == index else { reject("callback output PTS mismatch"); return nil }
                output["frame"] = index; output["sourcePTS"] = Self.time(frame.sourcePTS)
                output["encoderSessionID"] = frame.encoderSessionID.uuidString
                output["configurationID"] = frame.configuration.map { $0.id.uuidString as Any } ?? NSNull()
                output["configuredBitRate"] = frame.configuration.map { $0.bitRate as Any } ?? NSNull()
                output["submittedAt"] = frame.submittedAt; output["completedAt"] = frame.completedAt
                return output
            }
            return ["frames": rows, "errors": errors]
        }
    }
}
