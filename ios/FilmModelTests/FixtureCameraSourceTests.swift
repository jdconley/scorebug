import CoreMedia
import Foundation
import ScorebugMedia
import XCTest

final class FixtureCameraSourceTests: XCTestCase {
    func testLateFixtureCallbackDoesNotBurstRemainingFrames() async throws {
        let profile = ArchiveProfile(width: 320, height: 240)
        let source = FixtureCameraSource(profile: profile, failAfterFrames: 8)
        let diagnostics = ArchivePressureDiagnostics(recordingID: "late-producer")
        XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
        let ledger = FixtureHookLedger()
        let done = expectation(description: "Eight delayed frame pairs")
        let origin = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { sample in
            ledger.record(sample, snapshot: diagnostics.snapshot)
            if sample.kind == .video, diagnostics.snapshot.observations.activeProducer?.frameIndex == "0" {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }, event: { _ in done.fulfill() }))
        try await source.start()
        await fulfillment(of: [done], timeout: 3)
        await source.stop()
        let spans = diagnostics.snapshot.observations.producers.completed
        XCTAssertEqual(spans.count, 8)
        let starts = try spans.map { try XCTUnwrap($0.generationStart) }
        for start in starts {
            XCTAssertLessThanOrEqual(starts.filter { $0 >= start && $0 < start + 0.01 }.count, 2,
                                    "A late callback must not release its accumulated frame backlog")
        }
        // Nominal deadlines are not rewritten to hide a delayed producer.
        XCTAssertGreaterThan(try XCTUnwrap(spans[2].generationStart) - XCTUnwrap(spans[2].nominalDeadline), 0.15)
        XCTAssertEqual(ledger.entries.count, 16)
        for (index, entry) in ledger.entries.enumerated() {
            XCTAssertEqual(CMTimeCompare(entry.pts, origin + CMTime(value: Int64(index / 2), timescale: 30)), 0)
        }
    }

    func testFrameCadencePreservesNormalPhaseButDiscardsMissedWakeBacklog() {
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let origin = ContinuousClock.now
        var cadence = FixtureFrameCadence(origin: origin)
        cadence.began(frame: 0, at: origin)
        let normal = origin + .seconds(1.0 / 30)
        XCTAssertEqual(cadence.deadline(frame: 1), normal)
        cadence.began(frame: 1, at: normal + .milliseconds(5))
        // Ordinary timer jitter must not compound into a slower target rate.
        XCTAssertEqual(cadence.deadline(frame: 2), origin + .seconds(2.0 / 30))
        let resumed = origin + .seconds(1.5)
        cadence.began(frame: 2, at: resumed)
        XCTAssertEqual(seconds(resumed.duration(to: cadence.deadline(frame: 3))), 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(cadence.nominalDeadline(frame: 3), origin + .seconds(3.0 / 30))
        cadence.began(frame: 3, at: cadence.deadline(frame: 3) + .milliseconds(2))
        XCTAssertEqual(seconds(resumed.duration(to: cadence.deadline(frame: 4))), 2.0 / 30, accuracy: 1e-9)
    }

    func testDelayedFixturePreservesEverySampleThroughDefaultNativeArchiveQueue() async throws {
        let root = testRecordingRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile()
        let writer = try SegmentedArchiveWriter(directory: root.appendingPathComponent("part"), profile: profile)
        let session = try RecordingSession(sink: SegmentedArchiveSink(writer: writer))
        let source = FixtureCameraSource(profile: profile, failAfterFrames: 90, motionFlag: "blocks16")
        let diagnostics = ArchivePressureDiagnostics(recordingID: "delayed-native-archive")
        XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
        XCTAssertTrue(session.attachArchivePressureDiagnostics(diagnostics))
        XCTAssertTrue(writer.attachArchivePressureDiagnostics(diagnostics))
        let done = expectation(description: "Ninety source pairs")
        let origin = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { sample in
            if sample.kind == .video, diagnostics.snapshot.observations.activeProducer?.frameIndex == "10" {
                Thread.sleep(forTimeInterval: 1.5)
            }
            XCTAssertTrue(session.offer(sample))
        }, event: { event in
            // failAfterFrames is the finite test source boundary, not a device event.
            XCTAssertEqual(event, .interrupted)
            done.fulfill()
        }))
        try await session.start(at: origin)
        try await source.start()
        await fulfillment(of: [done], timeout: 15)
        await source.stop()
        let recovered = try await session.stop()
        diagnostics.close(snapshot: session.snapshot)
        let exported = try await ArchiveExporter().export(recovered, to: root.appendingPathComponent("movie.mp4"))
        XCTAssertEqual(exported.videoFrames, 90)
        XCTAssertGreaterThanOrEqual(exported.audioSamples, 144_000)
        XCTAssertLessThanOrEqual(exported.audioSamples, 146_048)
        XCTAssertEqual(session.snapshot.writtenSamples, 180)
        XCTAssertEqual(session.snapshot.queue.rejectedCount, 0)
        XCTAssertEqual(session.snapshot.queue.droppedCount, 0)
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertNil(diagnostics.snapshot.firstFailure)
        XCTAssertEqual(diagnostics.snapshot.queueLimits?.maxBytes, String(24 * 1024 * 1024))
    }

    func testAudioMarkersHaveSilenceBetweenDistinctTimedBursts() {
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: 0.5), 0)
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: 1.99), 0)
        let firstTime = 1.0 / 48_000
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: firstTime), Int16(0.5 * 32767 * sin(2 * .pi * 1000 * firstTime)))
        let secondTime = 2 + firstTime
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: secondTime), Int16(0.5 * 32767 * sin(2 * .pi * 1020 * secondTime)))
    }

    func testDiagnosticHooksPreserveIndicesPTSAndCallbackOrder() async throws {
        for motionFlag in [nil, "1", "blocks16"] as [String?] {
            let profile = ArchiveProfile(width: 320, height: 240)
            let source = FixtureCameraSource(profile: profile, failAfterFrames: 3, motionFlag: motionFlag)
            let diagnostics = ArchivePressureDiagnostics(recordingID: "fixture")
            XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
            XCTAssertFalse(source.attachArchivePressureDiagnostics(ArchivePressureDiagnostics(recordingID: "other")))
            let ledger = FixtureHookLedger()
            let done = expectation(description: "Three frame pairs")
            let origin = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { sample in
                ledger.record(sample, snapshot: diagnostics.snapshot)
            }, event: { _ in done.fulfill() }))
            let late = ArchivePressureDiagnostics(recordingID: "late")
            XCTAssertFalse(source.attachArchivePressureDiagnostics(late))
            XCTAssertFalse(late.snapshot.coverage.producer)
            try await source.start()
            await fulfillment(of: [done], timeout: 3)
            await source.stop()
            let entries = ledger.entries
            XCTAssertEqual(entries.map(\.kind), ["video", "audio", "video", "audio", "video", "audio"])
            for (index, entry) in entries.enumerated() {
                XCTAssertEqual(CMTimeCompare(entry.pts, origin + CMTime(value: Int64(index / 2), timescale: 30)), 0)
                XCTAssertEqual(entry.active?.frameIndex, String(index / 2))
                XCTAssertNotNil(entry.active?.generationEnd)
                XCTAssertNotNil(entry.active?.callbackStart)
                XCTAssertNil(entry.active?.callbackEnd)
            }
            let spans = diagnostics.snapshot.observations.producers.completed
            XCTAssertEqual(spans.map(\.frameIndex), ["0", "1", "2"])
            for index in 1..<spans.count {
                XCTAssertEqual(try XCTUnwrap(spans[index].deadline) - XCTUnwrap(spans[index - 1].deadline), 1.0 / 30, accuracy: 0.000001)
            }
            XCTAssertTrue(diagnostics.snapshot.coverage.producer)
            XCTAssertNil(diagnostics.snapshot.observations.activeProducer)
        }
    }

    func testFailureInsideVideoCallbackRetainsPartialProducerAndLateCallsDoNotReadClock() async throws {
        let clock = FixtureDiagnosticClock()
        let diagnostics = ArchivePressureDiagnostics(recordingID: "partial", now: { clock.read() })
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(sink: testArchiveSink(root, ArchiveProfile()))
        XCTAssertTrue(session.attachArchivePressureDiagnostics(diagnostics))
        let source = FixtureCameraSource(profile: ArchiveProfile(width: 320, height: 240), failAfterFrames: 1)
        XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
        let done = expectation(description: "Fixture ends")
        _ = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { sample in
            if sample.kind == .video {
                session.failCapture(reason: "test private detail")
                diagnostics.close(snapshot: session.snapshot)
                clock.markClosed()
            }
        }, event: { _ in done.fulfill() }))
        try await source.start()
        await fulfillment(of: [done], timeout: 3)
        await source.stop()
        let snapshot = diagnostics.snapshot
        let active = try XCTUnwrap(snapshot.firstFailure?.observations.activeProducer)
        XCTAssertEqual(active.frameIndex, "0")
        XCTAssertNotNil(active.generationEnd)
        XCTAssertNotNil(active.callbackStart)
        XCTAssertNil(active.callbackEnd)
        XCTAssertEqual(snapshot.observations.activeProducer, active)
        XCTAssertEqual(clock.readsAfterClose, 0)
    }

    func testSimulatorSourceProducesExportableRealMediaAndStops() async throws {
        for motionFlag in [nil, "1", "blocks16"] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let profile = ArchiveProfile(width: 640, height: 360, videoBitRate: 1_000_000)
            let writer = try SegmentedArchiveWriter(directory: root.appendingPathComponent("part"), profile: profile)
            let owner = CaptureRecording(source: FixtureCameraSource(profile: profile, motionFlag: motionFlag),
                session: try RecordingSession(sink: SegmentedArchiveSink(writer: writer)))
            try await owner.start()
            let deadline = ContinuousClock.now + .seconds(10)
            while writer.snapshot.acceptedDuration < 3 {
                guard ContinuousClock.now < deadline else { XCTFail("Fixture failed to advance"); owner.cancel(); return }
                try await Task.sleep(for: .milliseconds(50))
            }
            let recovered = try await owner.stop()
            let samplesAfterStop = owner.snapshot.writtenSamples
            let exported = try await ArchiveExporter().export(recovered, to: root.appendingPathComponent("movie.mp4"))
            XCTAssertGreaterThanOrEqual(exported.videoFrames, 89)
            XCTAssertGreaterThanOrEqual(exported.audioSamples, 140_000)
            XCTAssertLessThan(exported.duration, 5, "Nonzero fixture origin must not create a blank lead-in")
            XCTAssertEqual(owner.snapshot.writtenSamples, samplesAfterStop)
            XCTAssertEqual(owner.snapshot.state, .finished)
        }
    }
}

private final class FixtureHookLedger: @unchecked Sendable {
    struct Entry { let kind: String; let pts: CMTime; let active: ArchivePressureDiagnostics.Producer? }
    private let lock = NSLock()
    private var values: [Entry] = []
    var entries: [Entry] { lock.withLock { values } }
    func record(_ sample: CapturedMediaSample, snapshot: ArchivePressureDiagnostics.Snapshot) {
        lock.withLock { values.append(Entry(kind: sample.kind == .video ? "video" : "audio", pts: sample.sampleBuffer.presentationTimeStamp, active: snapshot.observations.activeProducer)) }
    }
}

private final class FixtureDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var late = 0
    var readsAfterClose: Int { lock.withLock { late } }
    func markClosed() { lock.withLock { closed = true } }
    func read() -> ContinuousClock.Instant { lock.withLock { if closed { late += 1 }; return .now } }
}
