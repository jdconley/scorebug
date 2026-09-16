@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import VideoToolbox
import XCTest
@testable import HaishinKit

/// Same encoder and DEBUG frame generator as the native publishing fixture.
/// The only retained output is scalar metadata; no media enters a socket.
final class EncoderPayloadTests: XCTestCase {
    @MainActor func testControlledRatesAndFreshLowEncoder() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Encoder payload qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile()
        let motion = try FixtureMotionPattern(profile: profile, pattern: .blocks16)
        let dynamic = await measure(name: "dynamic", rates: [6_000_000, 1_500_000, 6_000_000], profile: profile, motion: motion)
        let fresh = await measure(name: "freshLow", rates: [1_500_000], profile: profile, motion: motion)
        let report: [String: Any] = [
            "formatVersion": 1, "platform": "iOS Simulator", "workload": "motion-blocks16",
            "width": profile.width, "height": profile.height, "framesPerSecond": 30,
            "phaseFrames": 600, "settlingFrames": 150, "runs": [dynamic, fresh]
        ]
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
                                    motion: FixtureMotionPattern) async -> [String: Any] {
        let expected = rates.count * 600 + 1
        let recorder = PayloadRecorder(limit: expected)
        let codec = VideoCodec(encoderConfigurationObserver: recorder.observe)
        // Fresh-low is configured before bootstrap, not lowered from 6 Mbps.
        codec.settings = VideoCodecSettings(videoSize: CGSize(width: 1920, height: 1080),
            bitRate: rates[0], profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2, allowFrameReordering: false, expectedFrameRate: 30)
        let output = codec.outputStream
        let consumer = Task.detached {
            for await sample in output { recorder.deliver(sample) }
        }
        var receipts: [[String: Any]] = []
        var failure: String?
        var anchor = ProcessInfo.processInfo.systemUptime
        var bootstrapNativeBitRate = 0
        codec.startRunning()
        do {
            let origin = CMTime(value: 7395, timescale: 60)
            codec.append(try FixtureCameraSource.video(frame: 0, profile: profile, origin: origin, motion: motion))
            guard let nativeSession = codec.session else { throw ProbeError.session }
            let session = nativeSession as! VTCompressionSession
            var nativeRate: CFTypeRef?
            guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                allocator: kCFAllocatorDefault, valueOut: &nativeRate) == noErr,
                let nativeRate = nativeRate as? NSNumber else { throw ProbeError.nativeRate }
            bootstrapNativeBitRate = nativeRate.intValue
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
        codec.stopRunning()
        await consumer.value
        var report = recorder.report()
        report["name"] = name; report["receipts"] = receipts; report["pacingAnchor"] = anchor
        report["bootstrapNativeBitRate"] = bootstrapNativeBitRate
        report["nativeFailure"] = failure.map { $0 as Any } ?? NSNull()
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
    private var outputs: [Int: (bytes: Int, at: Double, pts: CMTime)] = [:]
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
                  sample.imageBuffer == nil, CMSampleBufferGetTotalSampleSize(sample) > 0 else {
                reject("invalid/duplicate compressed output"); return
            }
            outputs[index] = (CMSampleBufferGetTotalSampleSize(sample), at, sample.presentationTimeStamp)
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
                    "deliveredAt": output.at, "bytes": output.bytes]
            }
            return ["frames": rows, "errors": errors]
        }
    }
}
