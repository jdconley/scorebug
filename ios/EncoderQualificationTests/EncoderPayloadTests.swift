@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import VideoToolbox
import XCTest
@testable import HaishinKit

/// Same encoder and DEBUG frame generator as the native publishing fixture.
/// The only retained output is scalar metadata; no media enters a socket.
final class EncoderPayloadTests: XCTestCase {
    @MainActor func testFreshLowLatencyAverageOnly() async throws {
        #if !os(macOS)
        throw XCTSkip("Average-only encoder qualification requires native macOS")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var normal = await measure(name: "freshDefault", rates: [1_500_000], profile: profile, motion: motion)
        var lowLatency = await measure(name: "freshLowLatency", rates: [1_500_000], profile: profile, motion: motion,
                                       lowLatencyRateControl: true, omitDataRateLimits: true)
        normal["dataRateLimitsRequested"] = "rate-times-1.5"
        lowLatency["dataRateLimitsRequested"] = "omitted"
        normal["lowLatencyRateControlRequested"] = false
        lowLatency["lowLatencyRateControlRequested"] = true
        normal["encodedWidth"] = 1920; normal["encodedHeight"] = 1080
        lowLatency["encodedWidth"] = 1920; lowLatency["encodedHeight"] = 1080
        let report: [String: Any] = [
            "formatVersion": 11, "experiment": "native-low-latency-average-only",
            "platform": "macOS", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [normal, lowLatency]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderLowLatencyAverageOnly"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [normal, lowLatency] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    @MainActor func testFreshLowLatencyRateControl() async throws {
        #if !targetEnvironment(simulator) && !os(macOS)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var normal = await measure(name: "freshDefault", rates: [1_500_000], profile: profile, motion: motion)
        var lowLatency = await measure(name: "freshLowLatency", rates: [1_500_000], profile: profile, motion: motion,
                                       lowLatencyRateControl: true)
        normal["lowLatencyRateControlRequested"] = false
        lowLatency["lowLatencyRateControlRequested"] = true
        normal["encodedWidth"] = 1920; normal["encodedHeight"] = 1080
        lowLatency["encodedWidth"] = 1920; lowLatency["encodedHeight"] = 1080
        var report: [String: Any] = [
            "formatVersion": 5, "experiment": "fresh-low-latency-rate-control",
            "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [normal, lowLatency]
        ]
        #if os(macOS)
        report["formatVersion"] = 10
        report["platform"] = "macOS"
        #endif
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderLowLatency"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [normal, lowLatency] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    @MainActor func testFreshHalfResolutionProfiles() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var full = await measure(name: "fresh1080p", rates: [1_500_000], profile: profile, motion: motion)
        var reduced = await measure(name: "fresh540p", rates: [1_500_000], profile: profile, motion: motion,
                                    outputSize: CGSize(width: 960, height: 540))
        full["encodedWidth"] = 1920; full["encodedHeight"] = 1080
        reduced["encodedWidth"] = 960; reduced["encodedHeight"] = 540
        let report: [String: Any] = [
            "formatVersion": 6, "experiment": "fresh-half-resolution-profiles",
            "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [full, reduced]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderHalfResolution"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [full, reduced] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    @MainActor func testFreshResolutionProfiles() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var full = await measure(name: "fresh1080p", rates: [1_500_000], profile: profile, motion: motion)
        var reduced = await measure(name: "fresh720p", rates: [1_500_000], profile: profile, motion: motion,
                                    outputSize: CGSize(width: 1280, height: 720))
        full["encodedWidth"] = 1920; full["encodedHeight"] = 1080
        reduced["encodedWidth"] = 1280; reduced["encodedHeight"] = 720
        let report: [String: Any] = [
            "formatVersion": 4, "experiment": "fresh-resolution-profiles",
            "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [full, reduced]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderResolution"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [full, reduced] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    @MainActor func testFreshFrameRatePreparation() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var late = await measure(name: "freshLate", rates: [1_500_000], profile: profile, motion: motion)
        var early = await measure(name: "freshEarly", rates: [1_500_000], profile: profile, motion: motion, prepareFrameRateEarly: true)
        late["preparation"] = "production"
        early["preparation"] = "expectedFrameRateBeforePrepare"
        let report: [String: Any] = [
            "formatVersion": 3, "experiment": "frame-rate-before-prepare",
            "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [late, early]
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderPreparation"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [late, early] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    /// Controlled test-only copy of VTSessionMode's compression factory. Its only
    /// configuration difference is ExpectedFrameRate before preparation.
    private static func earlyFrameRateSession(_ mode: VTSessionMode, _ codec: VideoCodec) throws -> any VTSessionConvertible {
        guard case .compression = mode else { throw ProbeError.session }
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(codec.settings.videoSize.width), height: Int32(codec.settings.videoSize.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: codec.settings.makeEncoderSpecification(),
            imageBufferAttributes: codec.makeImageBufferAttributes(.compression) as CFDictionary?,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw VTSessionError.failedToCreate(status: status) }
        do {
            status = session.setOptions(codec.settings.makeOptions())
            guard status == noErr else { throw VTSessionError.failedToPrepare(status: status) }
            status = session.setOption(.init(key: .expectedFrameRate, value: 30 as CFNumber))
            guard status == noErr else { throw VTSessionError.failedToPrepare(status: status) }
            status = session.prepareToEncodeFrames()
            guard status == noErr else { throw VTSessionError.failedToPrepare(status: status) }
            codec.frameInterval = codec.settings.frameInterval
            return session
        } catch { session.invalidate(); throw error }
    }

    @MainActor func testControlledRatesAndFreshLowEncoder() async throws {
        #if !targetEnvironment(simulator) && !os(macOS)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        var dynamic = await measure(name: "dynamic", rates: [6_000_000, 1_500_000, 6_000_000], profile: profile, motion: motion)
        var fresh = await measure(name: "freshLow", rates: [1_500_000], profile: profile, motion: motion)
        var report: [String: Any] = [
            "formatVersion": 2, "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [dynamic, fresh]
        ]
        #if os(macOS)
        for key in ["encodedWidth", "encodedHeight"] {
            dynamic[key] = key == "encodedWidth" ? 1920 : 1080
            fresh[key] = key == "encodedWidth" ? 1920 : 1080
        }
        report["formatVersion"] = 9
        report["platform"] = "macOS"
        report["experiment"] = "native-mac-rate-control"
        report["runs"] = [dynamic, fresh]
        #endif
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderPayload"; attachment.lifetime = .keepAlways
        add(attachment)
        for run in [dynamic, fresh] {
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["errors"] as? [String], [])
        }
    }

    @MainActor private func measure(name: String, rates: [Int], profile: ArchiveProfile,
                                    motion: FixtureMotionPattern, prepareFrameRateEarly: Bool = false,
                                    outputSize: CGSize = CGSize(width: 1920, height: 1080),
                                    lowLatencyRateControl: Bool = false, omitDataRateLimits: Bool = false) async -> [String: Any] {
        let expected = rates.count * 600 + 1
        let recorder = PayloadRecorder(limit: expected)
        let codec = VideoCodec(encoderConfigurationObserver: recorder.observe,
            sessionFactory: prepareFrameRateEarly ? Self.earlyFrameRateSession : nil)
        // Fresh-low is configured before bootstrap, not lowered from 6 Mbps.
        codec.settings = VideoCodecSettings(videoSize: outputSize,
            bitRate: rates[0], profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false,
            dataRateLimits: omitDataRateLimits ? nil : [0.0, 0.0],
            isLowLatencyRateControlEnabled: lowLatencyRateControl, expectedFrameRate: 30)
        let output = codec.outputStream
        let consumer = Task.detached {
            for await sample in output { recorder.deliver(sample) }
        }
        var receipts: [[String: Any]] = []
        var failure: String?
        var anchor = ProcessInfo.processInfo.systemUptime
        var bootstrapNativeBitRate = 0
        var native: [String: Any] = [:]
        var originalSession: VTCompressionSession?
        codec.startRunning()
        do {
            let origin = CMTime(value: 7395, timescale: 60)
            codec.append(try FixtureCameraSource.video(frame: 0, profile: profile, origin: origin, motion: motion))
            guard let nativeSession = codec.session else { throw ProbeError.session }
            let session = nativeSession as! VTCompressionSession
            originalSession = session
            var nativeRate: CFTypeRef?
            guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                allocator: kCFAllocatorDefault, valueOut: &nativeRate) == noErr,
                let nativeRate = nativeRate as? NSNumber else { throw ProbeError.nativeRate }
            bootstrapNativeBitRate = nativeRate.intValue
            native["bootstrap"] = try NativeEncoderSnapshot.capture(session)
            // Bootstrap session creation is outside the paced interval.
            anchor = ProcessInfo.processInfo.systemUptime
            let began = ContinuousClock.now
            var lastAppendFinished = began
            for frame in 1..<expected {
                // Generate before pacing so variable pixel-generation time does
                // not turn a late frame into an immediate catch-up submission.
                let inputFrame = (frame - 1) % 600 + 1
                let inputOrigin = origin + CMTime(value: Int64(frame - inputFrame), timescale: 30)
                let sample = try autoreleasepool {
                    try FixtureCameraSource.video(frame: inputFrame, profile: profile, origin: inputOrigin, motion: motion)
                }
                let deadline = max(began + .seconds(Double(frame) / 30), lastAppendFinished + .seconds(1.0 / 60))
                try await ContinuousClock().sleep(until: deadline)
                let phase = (frame - 1) / 600
                if (frame - 1).isMultiple(of: 600) {
                    _ = try codec.setVerifiedBitRate(rates[phase])
                    guard let change = codec.lastBitRateChange,
                          let previous = change.lastSubmittedSourcePTS,
                          let previousFrame = PayloadRecorder.frameID(previous) else { throw ProbeError.receipt }
                    receipts.append(["firstFrame": frame, "frameCount": 600, "bitRate": change.configuration.bitRate,
                        "configurationID": change.configuration.id.uuidString,
                        "encoderSessionID": change.configuration.encoderSessionID.uuidString,
                        "acceptedAt": change.acceptedAt, "lastSubmittedFrame": previousFrame])
                }
                // Identical pixels and barcode per phase; only source PTS advances.
                codec.append(sample)
                lastAppendFinished = ContinuousClock.now
                if codec.failure.error != nil { throw ProbeError.codec }
            }
        } catch { failure = String(describing: error) }
        let complete = codec.makeCompletion()
        await Task.detached { complete() }.value
        if let error = codec.failure.error { failure = String(describing: error) }
        do {
            guard let originalSession, let current = codec.session,
                  let configuration = codec.lastBitRateChange?.configuration,
                  receipts.allSatisfy({ $0["encoderSessionID"] as? String == configuration.encoderSessionID.uuidString }),
                  ObjectIdentifier(originalSession) == ObjectIdentifier(current as! VTCompressionSession)
            else { throw ProbeError.session }
            native["final"] = try NativeEncoderSnapshot.capture(originalSession)
            for key in ["bootstrap", "final"] {
                guard var snapshot = native[key] as? [String: Any] else { throw ProbeError.session }
                snapshot["encoderSessionID"] = configuration.encoderSessionID.uuidString
                native[key] = snapshot
            }
        } catch { if failure == nil { failure = String(describing: error) } }
        codec.stopRunning()
        await consumer.value
        var report = recorder.report()
        report["name"] = name; report["receipts"] = receipts; report["pacingAnchor"] = anchor
        report["bootstrapNativeBitRate"] = bootstrapNativeBitRate
        report["nativeFailure"] = failure.map { $0 as Any } ?? NSNull()
        report["native"] = native
        return report
    }
    private enum ProbeError: Error { case session, nativeRate, receipt, codec }
}

/// A bounded join between callback metadata and actual compressed output.
/// All values are copied scalars; callback arrival order may differ.
private final class PayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var observations: [Int: VideoEncoderFrame] = [:]
    private var outputs: [Int: (bytes: Int, at: Double, pts: CMTime, width: Int32, height: Int32)] = [:]
    private var errors: [String] = []
    init(limit: Int) { self.limit = limit }

    static func frameID(_ time: CMTime) -> Int? {
        guard time.isValid, time.isNumeric, time.epoch == 0 else { return nil }
        let delta = time - CMTime(value: 7395, timescale: 60)
        let scaled = CMTimeConvertScale(delta, timescale: 30, method: .default)
        guard scaled.isNumeric, scaled.value >= 0, scaled.value <= 2402,
              CMTimeCompare(scaled, delta) == 0 else { return nil }
        return Int(scaled.value)
    }
    private func reject(_ reason: String) { if errors.count < 8 { errors.append(reason) } }
    func observe(_ frame: VideoEncoderFrame) {
        lock.withLock {
            guard let index = Self.frameID(frame.sourcePTS), index < limit,
                  observations[index] == nil, observations.count < limit else {
                reject("invalid/duplicate observation"); return
            }
            observations[index] = frame
        }
    }
    func deliver(_ sample: CMSampleBuffer) {
        let at = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard let index = Self.frameID(sample.presentationTimeStamp), index < limit,
                  outputs[index] == nil, outputs.count < limit,
                  CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  sample.imageBuffer == nil, CMSampleBufferGetTotalSampleSize(sample) > 0,
                  let format = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
                reject("invalid/duplicate compressed output"); return
            }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            guard size.width > 0, size.height > 0 else { reject("invalid encoded dimensions"); return }
            outputs[index] = (CMSampleBufferGetTotalSampleSize(sample), at, sample.presentationTimeStamp, size.width, size.height)
        }
    }
    private func time(_ t: CMTime) -> [String: Any] {
        ["value": String(t.value), "timescale": t.timescale, "epoch": String(t.epoch), "flags": t.flags.rawValue]
    }
    func report() -> [String: Any] {
        lock.withLock {
            if observations.count != limit || outputs.count != limit { reject("incomplete frame join") }
            let rows: [[String: Any]] = observations.keys.sorted().compactMap { index in
                guard let frame = observations[index], let output = outputs[index] else { return nil }
                guard CMTimeCompare(frame.outputPTS, output.pts) == 0 else { reject("output PTS mismatch"); return nil }
                return ["frame": index, "sourcePTS": time(frame.sourcePTS), "outputPTS": time(output.pts),
                    "encoderSessionID": frame.encoderSessionID.uuidString,
                    "configurationID": frame.configuration.map { $0.id.uuidString as Any } ?? NSNull(),
                    "configuredBitRate": frame.configuration.map { $0.bitRate as Any } ?? NSNull(),
                    "submittedAt": frame.submittedAt, "completedAt": frame.completedAt,
                    "deliveredAt": output.at, "bytes": output.bytes,
                    "encodedWidth": output.width, "encodedHeight": output.height]
            }
            return ["frames": rows, "errors": errors]
        }
    }
}
