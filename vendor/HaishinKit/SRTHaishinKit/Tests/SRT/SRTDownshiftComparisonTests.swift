@preconcurrency import AVFoundation
import Foundation
import VideoToolbox
import Testing
@testable import HaishinKit
@testable import SRTHaishinKit

/// Opt-in diagnostic, never a transport/media qualification. Each case owns its
/// native encoder and finite reader. Callbacks retain scalars only, never media.
@Suite(.serialized) struct SRTDownshiftComparisonTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCOREBUG_DOWNSHIFT_SOURCE"] != nil),
          .timeLimit(.minutes(1)))
    @MainActor func nativeComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = try #require(environment["SCOREBUG_DOWNSHIFT_CASE"])
        try #require(["resize", "rate", "rate-resize"].contains(mode))
        let source = try #require(environment["SCOREBUG_DOWNSHIFT_SOURCE"])
        let destination = try #require(environment["SCOREBUG_DOWNSHIFT_OUTPUT"])
        try #require(source.hasPrefix("/") && destination.hasPrefix("/"))
        let output = URL(fileURLWithPath: destination).appendingPathComponent(mode + ".json")
        try #require(!FileManager.default.fileExists(atPath: output.path))
        let trace = DownshiftTrace(limit: 20_000)
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            trace.record("send", fields: ["bytes": String(data.count)])
            return Int32(data.count)
        }))
        let stream = SRTStream(connection: connection,
            encoderConfigurationObserver: { frame in
                var fields = ["pts": exactPTS(frame.sourcePTS), "outputPTS": exactPTS(frame.outputPTS),
                    "encoder": frame.encoderSessionID.uuidString, "submittedAt": String(frame.submittedAt),
                    "completedAt": String(frame.completedAt)]
                if let configuration = frame.configuration {
                    fields["configuration"] = configuration.id.uuidString
                    fields["bitrate"] = String(configuration.bitRate)
                }
                trace.record("completed", at: frame.completedAt, fields: fields)
            }, compressedVideoObserver: { frame in
                trace.record("compressed", at: frame.dequeuedAt, fields: ["pts": exactPTS(frame.sourcePTS),
                    "generation": String(frame.publishingGeneration), "width": String(frame.width),
                    "height": String(frame.height), "bytes": String(frame.byteCount), "codec": String(frame.codec),
                    "valid": String(frame.valid), "encoded": String(frame.wasEncoded),
                    "sync": frame.isSync.map(String.init) ?? "unknown", "paced": String(frame.sourceCadencePaced)])
            }, muxedPacketObserver: { frame in
                trace.record("muxed", at: frame.observedAt, fields: ["pts": exactPTS(frame.sourcePTS),
                    "generation": String(frame.publishingGeneration), "media": frame.media.rawValue,
                    "transportPTS": String(frame.transportPTS), "dts": exactPTS(frame.sourceDTS)])
            }, encoderSubmissionObserver: { frame in
                trace.record("submitted", at: frame.startedAt, fields: ["pts": exactPTS(frame.sourcePTS),
                    "encoder": frame.encoderSessionID.uuidString, "returnedAt": String(frame.returnedAt),
                    "status": String(frame.status), "selection": String(describing: frame.selectionQueriedAfterPreparation)])
            })
        var reader: AVAssetReader?
        var mutation: Task<Void, Error>?
        var failure: String?
        var drainCompleted = false
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: source))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let segments = try await track.load(.segments)
            let media = segments.filter { !$0.isEmpty }
            try #require(media.count == 1)
            let range = try #require(media.first).timeMapping.target
            try #require(range.start.isNumeric && range.duration.seconds >= 132)
            let selectedStart = range.start + CMTime(value: 120, timescale: 1)
            let nativeReader = try AVAssetReader(asset: asset)
            reader = nativeReader
            // Same twelve seconds of the verified volleyball derivative in every
            // case. Preserve original PTS; publishing selects its own TS anchor.
            nativeReader.timeRange = CMTimeRange(start: selectedStart,
                                                 duration: CMTime(value: 12, timescale: 1))
            let video = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            video.alwaysCopiesSampleData = false
            try #require(nativeReader.canAdd(video)); nativeReader.add(video)
            try #require(nativeReader.startReading())
            await connection.addStream(stream)
            try await connection.connect(URL(string: "srt://127.0.0.1:1")!)
            try await stream.setVideoSettings(downshiftSettings(width: 1280, height: 720, rate: 3_000_000))
            await stream.setVideoInputBufferCounts(4)
            await stream.setExpectedMedias([.video]); await stream.publish()
            let generation = try #require(await stream.publishingGeneration)
            trace.record("started", fields: ["generation": String(generation), "source": source, "mode": mode,
                "sourceMediaStart": exactPTS(range.start), "selectedStart": exactPTS(selectedStart)])
            let clock = ContinuousClock(), start = ContinuousClock.now
            var baseline: SRTStream.VideoBitRateReceipt?
            for index in 0..<360 {
                try Task.checkCancellation()
                let sample = try #require(video.copyNextSampleBuffer())
                try await clock.sleep(until: start + .nanoseconds(Int64(index) * 1_000_000_000 / 30))
                trace.record("input", fields: ["index": String(index), "pts": exactPTS(sample.presentationTimeStamp)])
                await stream.append(sample)
                if index == 30 {
                    let receipt = try await stream.setVerifiedVideoBitRateWithReceipt(3_000_000, publishingGeneration: generation)
                    baseline = receipt
                    trace.recordRate("baseline", receipt)
                }
                if index == 180 {
                    let original = try #require(baseline)
                    trace.record("mutation-requested")
                    mutation = Task {
                        trace.record("mutation-started")
                        var expected = VideoBitRateExpectation(original.change)
                        if mode != "resize" {
                            let rate = try await stream.setVerifiedVideoBitRateWithReceipt(600_000,
                                expecting: .verified(publishingGeneration: generation, configuration: expected))
                            trace.recordRate("rate-receipt", rate)
                            expected = VideoBitRateExpectation(rate.change)
                        }
                        if mode != "rate" {
                            trace.record("resize-requested")
                            let receipt = try await stream.replaceVideoSettings(downshiftSettings(width: 640, height: 360, rate: 600_000),
                                publishingGeneration: generation, expecting: expected)
                            trace.record("resize-receipt", fields: ["generation": String(receipt.publishingGeneration),
                                "encoder": receipt.encoderSessionID.uuidString, "previousEncoder": receipt.previousEncoderSessionID.uuidString,
                                "oldPTS": exactPTS(receipt.lastOldSourcePTS), "newPTS": exactPTS(receipt.firstNewSourcePTS),
                                "width": String(receipt.width), "height": String(receipt.height), "rawDropped": String(receipt.rawVideoFramesDropped)])
                            let finalRate = try await stream.setVerifiedVideoBitRateWithReceipt(600_000, expecting: .replacement(receipt))
                            trace.recordRate("final-rate-receipt", finalRate)
                        }
                        trace.record("mutation-finished")
                    }
                }
            }
            try #require(video.copyNextSampleBuffer() == nil)
            try #require(nativeReader.status == .completed)
            try await mutation?.value
            try #require(await stream.publishingGeneration == generation)
            await stream.finish()
            try #require(await stream.publishingError == nil)
            drainCompleted = true
            trace.record("finished")
        } catch { failure = String(describing: error) }
        // Always join the mutation and await cleanup calls. On an aborted run, close
        // does not join every consumer: only successful finish proves full drain.
        // Run one case per process and require that process to exit before another.
        mutation?.cancel()
        await stream.close()
        _ = await mutation?.result
        await connection.close()
        reader?.cancelReading()
        let snapshot = trace.snapshot
        if snapshot.overflow { failure = [failure, "Trace overflow"].compactMap { $0 }.joined(separator: "; ") }
        for kind in ["input", "compressed", "muxed"] {
            if snapshot.events.filter({ $0.kind == kind }).count != 360 {
                failure = [failure, "Expected 360 \(kind) events"].compactMap { $0 }.joined(separator: "; ")
            }
        }
        let report = DownshiftReport(mode: mode, source: source, cleanupCallsCompleted: true,
            drainCompleted: drainCompleted, failure: failure, overflow: snapshot.overflow, events: snapshot.events)
        try JSONEncoder().encode(report).write(to: output, options: .withoutOverwriting)
        try #require(failure == nil, Comment(rawValue: failure ?? ""))
        try #require(drainCompleted)

    }

    @Test func traceIsBoundedAndDetached() {
        let trace = DownshiftTrace(limit: 2)
        trace.record("a", at: 1); let saved = trace.snapshot
        trace.record("b", at: 2); trace.record("c", at: 3)
        #expect(saved.events.map(\.kind) == ["a"])
        #expect(!saved.overflow)
        #expect(trace.snapshot.events.map(\.kind) == ["a", "b"])
        #expect(trace.snapshot.overflow)
    }
}

private func downshiftSettings(width: Int, height: Int, rate: Int) -> VideoCodecSettings {
    .init(videoSize: CGSize(width: width, height: height), bitRate: rate,
          profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
          maxKeyFrameIntervalDuration: 2, allowFrameReordering: false, expectedFrameRate: 30)
}
private func exactPTS(_ value: CMTime) -> String {
    "\(value.value)/\(value.timescale):\(value.epoch):\(value.flags.rawValue)"
}
private struct DownshiftEvent: Codable, Sendable {
    let kind: String
    let at: Double
    let fields: [String: String]
}
private struct DownshiftReport: Codable {
    let mode: String
    let source: String
    let cleanupCallsCompleted: Bool
    let drainCompleted: Bool
    let failure: String?
    let overflow: Bool
    let events: [DownshiftEvent]
}
private final class DownshiftTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var events: [DownshiftEvent] = []
    private var overflow = false
    init(limit: Int) { self.limit = limit }
    func record(_ kind: String, at: Double = ProcessInfo.processInfo.systemUptime, fields: [String: String] = [:]) {
        lock.withLock {
            guard events.count < limit else { overflow = true; return }
            events.append(.init(kind: kind, at: at, fields: fields))
        }
    }
    func recordRate(_ kind: String, _ receipt: SRTStream.VideoBitRateReceipt) {
        let c = receipt.change
        record(kind, at: c.acceptedAt, fields: ["encoder": c.configuration.encoderSessionID.uuidString,
            "configuration": c.configuration.id.uuidString, "bitrate": String(c.configuration.bitRate),
            "lastPTS": c.lastSubmittedSourcePTS.map(exactPTS) ?? "none", "generation": String(receipt.publishingGeneration)])
    }
    var snapshot: (events: [DownshiftEvent], overflow: Bool) { lock.withLock { (events, overflow) } }
}
