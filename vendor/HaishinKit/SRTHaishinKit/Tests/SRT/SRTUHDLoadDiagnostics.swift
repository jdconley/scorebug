@preconcurrency import AVFoundation
import Foundation
import VideoToolbox
import Testing
@testable import HaishinKit
@testable import SRTHaishinKit

/// Opt-in throughput isolation. Fake transport accepts bytes; no network or decoded-media qualification.
@Suite(.serialized) struct SRTUHDLoadDiagnostics {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCOREBUG_UHD_LOAD_SOURCE"] != nil),
          .timeLimit(.minutes(1)), arguments: ProcessInfo.processInfo.environment["SCOREBUG_UHD_LOAD_REPLACE"] == "1" ? [1] : [1, 3])
    @MainActor func concurrentEncoders(count: Int) async throws {
        let env = ProcessInfo.processInfo.environment
        let replace = env["SCOREBUG_UHD_LOAD_REPLACE"] == "1"
        let source = try #require(env["SCOREBUG_UHD_LOAD_SOURCE"])
        let directory = try #require(env["SCOREBUG_UHD_LOAD_OUTPUT"])
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(replace ? "replacement" : "encoders")-\(count).json")
        try #require(!FileManager.default.fileExists(atPath: destination.path))
        let asset = AVURLAsset(url: URL(fileURLWithPath: source))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = .init(start: range.start + CMTime(value: 260, timescale: 1), duration: CMTime(value: 15, timescale: 1))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output); try #require(reader.startReading())
        defer { reader.cancelReading() }
        var streams: [SRTStream] = [], connections: [SRTConnection] = [], traces: [UHDLoadTrace] = []
        var mutation: Task<Void, Error>?
        var samples: [[String: Any]] = []
        var failure: Error?
        var duration = 0.0, maximumInputLateness = 0.0
        do {
            for _ in 0..<count {
                let trace = UHDLoadTrace()
                let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
                let stream = SRTStream(connection: connection,
                    compressedVideoObserver: { trace.output($0) },
                    encoderSubmissionObserver: { trace.submission($0) })
                streams.append(stream); connections.append(connection); traces.append(trace)
                await connection.addStream(stream)
                try await connection.connect(URL(string: "srt://127.0.0.1:1")!)
                try await stream.setVideoSettings(.init(videoSize: CGSize(width: replace ? 1920 : 3840, height: replace ? 1080 : 2160), bitRate: replace ? 6_000_000 : 24_000_000,
                    profileLevel: kVTProfileLevel_H264_High_AutoLevel as String, maxKeyFrameIntervalDuration: 2,
                    allowFrameReordering: false, expectedFrameRate: 30))
                await stream.setExpectedMedias([.video]); await stream.publish()
            }
            // Warm the decoder before the pacing anchor; keep the same finite footage for both cases.
            var sample = try #require(output.copyNextSampleBuffer())
            let start = ContinuousClock.now
            for frame in 0..<450 {
                if frame > 0 { sample = try #require(output.copyNextSampleBuffer()) }
                let deadline = start + .nanoseconds(Int64(frame) * 1_000_000_000 / 30)
                try await ContinuousClock().sleep(until: deadline)
                maximumInputLateness = max(maximumInputLateness, seconds(deadline.duration(to: .now)))
                for stream in streams { await stream.append(sample) }
                if frame.isMultiple(of: 30) {
                    samples.append(["frame": frame, "rawVideoDropped": await streams[0].rawVideoFramesDropped,
                        "firstEncoder": traces[0].snapshot()])
                }
                if replace && frame == 30 {
                    let stream = streams[0]
                    let generation = try #require(await stream.publishingGeneration)
                    let baseline = try await stream.setVerifiedVideoBitRateWithReceipt(6_000_000, publishingGeneration: generation)
                    mutation = Task {
                        let receipt = try await stream.replaceVideoSettings(.init(videoSize: CGSize(width: 3840, height: 2160), bitRate: 24_000_000,
                            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String, maxKeyFrameIntervalDuration: 2,
                            allowFrameReordering: false, expectedFrameRate: 30), publishingGeneration: generation,
                            expecting: VideoBitRateExpectation(baseline.change))
                        _ = try await stream.setVerifiedVideoBitRateWithReceipt(24_000_000, expecting: .replacement(receipt))
                    }
                }
            }
            duration = seconds(start.duration(to: .now))
            try await mutation?.value
        } catch { failure = error }
        mutation?.cancel(); _ = await mutation?.result
        var results: [[String: Any]] = []
        for (index, stream) in streams.enumerated() {
            await stream.finish()
            var row = traces[index].snapshot()
            row["rawVideoDropped"] = await stream.rawVideoFramesDropped
            row["publishingError"] = await stream.publishingError.map { String(describing: $0) } ?? "none"
            results.append(row)
            await stream.close(); await connections[index].close()
        }
        let result: [String: Any] = ["scope": "Native SDK encoder load only; fake accepting transport; no archive/proxy/network qualification",
            "encoders": count, "replacement": replace, "samples": samples, "offeredPerEncoder": 450, "inputDuration": duration,
            "maximumInputLateness": maximumInputLateness, "results": results,
            "failure": failure.map { String(describing: $0) } ?? "none"]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: destination, options: .withoutOverwriting)
        print("UHD_LOAD encoders=\(count) seconds=\(duration) result=\(destination.path)")
        if let failure { throw failure }
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private final class UHDLoadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0, completed = 0, errors = 0
    private var totalSeconds = 0.0, maximumSeconds = 0.0
    private var selection = "unknown"
    func submission(_ value: VideoEncoderSubmission) {
        lock.withLock {
            submitted += 1
            if value.status != noErr { errors += 1 }
            let seconds = value.returnedAt - value.startedAt
            totalSeconds += seconds; maximumSeconds = max(maximumSeconds, seconds)
            selection = String(describing: value.selectionQueriedAfterPreparation)
        }
    }
    func output(_ value: SRTStream.CompressedVideoFrame) { lock.withLock { completed += 1 } }
    func snapshot() -> [String: Any] {
        lock.withLock { ["submitted": submitted, "completed": completed, "submissionErrors": errors,
            "totalSubmissionSeconds": totalSeconds, "maximumSubmissionSeconds": maximumSeconds,
            "hardwareSelection": selection] }
    }
}
