@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import ScorebugStreaming
import VideoToolbox
import XCTest
@testable import HaishinKit

/// Isolates native buffering without changing the candidate owner's four-input
/// bound. This is a diagnostic recipe experiment, not live capacity admission.
final class EncoderFrameDelayTests: XCTestCase {
    @MainActor func testBoundedCandidateFrameDelay() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Frame-delay qualification requires the iOS simulator")
        #endif
        let profile = ArchiveProfile(), motion = try FixtureMotionPattern(profile: ArchiveProfile(), pattern: .blocks16)
        let scope = VideoFrameObservationScope(recordingID: "diagnostic", matchID: "diagnostic", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let settings = try PublishingCandidateEncoder(scope: scope, profile: .low360).requestedSettings
        var runs: [[String: Any]] = []
        for (name, limit, count) in [("defaultIdle", nil as Int?, 4), ("limitedIdle", 3, 4),
                                    ("limitedContinuous", 3, 121), ("defaultRepeat", nil, 4)] {
            runs.append(await measure(name: name, limit: limit, count: count, profile: profile, motion: motion, settings: settings))
        }
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "experiment": "candidate-frame-delay",
            "platform": "iOS Simulator", "workload": "motion-blocks16", "inputWidth": 1920, "inputHeight": 1080,
            "profile": "360p30", "firstSourceFrame": 758, "runs": runs], options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 512 * 1024)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "EncoderFrameDelay"; attachment.lifetime = .keepAlways; add(attachment)
        for run in runs {
            XCTAssertEqual(run["outcome"] as? String, "completed", run["name"] as? String ?? "")
            XCTAssertTrue(run["failure"] is NSNull, String(describing: run["failure"]))
            XCTAssertTrue(run["nativeFailure"] is NSNull, String(describing: run["nativeFailure"]))
            XCTAssertEqual(run["acceptedInputCount"] as? Int, run["outputCount"] as? Int)
            if run["requestedMaxFrameDelayCount"] is Int {
                XCTAssertEqual(run["propertyCopyStatus"] as? Int, 0)
                XCTAssertEqual(run["propertyValue"] as? Int, 3)
            }
        }
    }

    @MainActor private func measure(name: String, limit: Int?, count: Int, profile: ArchiveProfile,
                                    motion: FixtureMotionPattern, settings: VideoCodecSettings) async -> [String: Any] {
        let evidence = FrameDelayEvidence()
        let started = ProcessInfo.processInfo.systemUptime
        var inputs: [[String: Any]] = [], errorText: String?
        let candidate: VideoCandidateEncoder
        do {
            candidate = try VideoCandidateEncoder(settings: settings, sessionFactory: { mode, codec in
                let session = try mode.makeSession(codec)
                let setStatus = limit.map { session.setOption(.init(key: .maxFrameDelayCount, value: NSNumber(value: $0))) }
                let copied = session.copyOption(.maxFrameDelayCount)
                let number = copied.value.flatMap { value -> NSNumber? in
                    guard CFGetTypeID(value) == CFNumberGetTypeID(), let n = value as? NSNumber,
                          n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue else { return nil }
                    return n
                }
                evidence.property(set: setStatus, copied: copied.status, value: number?.intValue)
                if let limit, setStatus != noErr || copied.status != noErr || number?.intValue != limit {
                    session.invalidate()
                    throw VTSessionError.failedToPrepare(status: setStatus.flatMap { $0 != noErr ? $0 : nil } ?? copied.status.nonzeroFailure)
                }
                return session
            }, outputObserver: { evidence.observe($0) })
        } catch {
            return ["name": name, "failure": String(describing: error), "outcome": "failed"]
        }
        do {
            try await candidate.start()
            let origin = CMTime(value: 7395, timescale: 60)
            let began = ContinuousClock.now
            var previousOffer = began - .seconds(1)
            for index in 0..<count {
                let sample = try autoreleasepool {
                    try FixtureCameraSource.video(frame: 758 + index, profile: profile, origin: origin, motion: motion)
                }
                let deadline = max(began + .seconds(Double(index) / 30), previousOffer + .seconds(1.0 / 60))
                try await ContinuousClock().sleep(until: deadline)
                let at = ProcessInfo.processInfo.systemUptime, accepted = candidate.offer(sample)
                inputs.append(["frame": 758 + index, "offeredAt": at, "accepted": accepted])
                previousOffer = ContinuousClock.now
                if !accepted { break }
            }
            if count == 4 { try await Task.sleep(for: .seconds(1)) }
        } catch { errorText = String(describing: error) }
        let checkpoint = evidence.checkpoint()
        let result = errorText == nil ? await candidate.finish() : await candidate.cancel()
        let ended = ProcessInfo.processInfo.systemUptime
        var object: [String: Any] = ["name": name, "id": result.id.uuidString,
            "requestedMaxFrameDelayCount": limit as Any? ?? NSNull(), "startedAt": started,
            "beforeFinishAt": checkpoint.at, "beforeFinishOutputs": checkpoint.outputs, "endedAt": ended,
            "acceptedInputCount": result.acceptedInputCount, "outputCount": result.outputCount,
            "outcome": result.outcome.rawValue, "failure": (errorText ?? result.failure) as Any? ?? NSNull(),
            "nativeFailure": result.nativeFailure.map { String(describing: $0) } as Any? ?? NSNull(),
            "encoderSessionID": result.encoderSessionID?.uuidString as Any? ?? NSNull(), "inputs": inputs,
            "requested": ["width": settings.videoSize.width, "height": settings.videoSize.height, "bitRate": settings.bitRate,
                "profileLevel": settings.profileLevel, "expectedFrameRate": settings.expectedFrameRate as Any? ?? NSNull(),
                "maxKeyFrameIntervalDuration": settings.maxKeyFrameIntervalDuration,
                "allowFrameReordering": settings.allowFrameReordering as Any? ?? NSNull()],
            "frames": result.frames.map { f in ["sourcePTS": Self.time(f.sourcePTS), "outputPTS": Self.time(f.outputPTS),
                "encoderSessionID": f.encoderSessionID.uuidString, "submittedAt": f.submittedAt, "completedAt": f.completedAt,
                "dequeuedAt": f.dequeuedAt, "observedAt": evidence.observedAt(f.sourcePTS) as Any? ?? NSNull(),
                "byteCount": f.byteCount, "width": f.width, "height": f.height, "isSync": f.isSync] }]
        object.merge(evidence.properties) { _, new in new }
        return object
    }
    private static func time(_ value: CMTime) -> [String: Any] {
        ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
    }
}
private extension OSStatus {
    var nonzeroFailure: OSStatus { self == noErr ? kVTParameterErr : self }
}
private final class FrameDelayEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var propertyData: [String: Any] = [:]
    private var observed: [String: Double] = [:]
    func property(set: OSStatus?, copied: OSStatus, value: Int?) {
        lock.withLock {
            propertyData = ["propertySetStatus": set as Any? ?? NSNull(), "propertyCopyStatus": copied,
                "propertyValue": value as Any? ?? NSNull(), "propertyObservedAt": ProcessInfo.processInfo.systemUptime]
        }
    }
    private func key(_ t: CMTime) -> String { "\(t.value)/\(t.timescale)/\(t.epoch)" }
    func observe(_ frame: VideoCandidateEncoder.Frame) {
        lock.withLock { if observed.count < 121 { observed[key(frame.sourcePTS)] = ProcessInfo.processInfo.systemUptime } }
    }
    func checkpoint() -> (at: Double, outputs: Int) {
        lock.withLock { (ProcessInfo.processInfo.systemUptime, observed.count) }
    }
    func observedAt(_ time: CMTime) -> Double? { lock.withLock { observed[key(time)] } }
    var properties: [String: Any] { lock.withLock { propertyData } }
}
