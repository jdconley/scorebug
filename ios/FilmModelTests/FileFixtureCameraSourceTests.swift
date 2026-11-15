import AVFoundation
import Foundation
import ScorebugMedia
import XCTest

final class FileFixtureCameraSourceTests: XCTestCase {
    private let profile = ArchiveProfile(width: 320, height: 240)

    @MainActor func testFilmExportsClosedFileStatisticsAndJoinsFailingDiagnosticWriter() async throws {
        let movie = try await FileSourceTestMovie.make(frames: 30)
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let model = FilmModel(library: RecordingLibrary(rootDirectory: movie.root.appendingPathComponent("library")),
                              profile: profile, sourceFactory: { source })
        let gate = FilmTestGate()
        var exports: [(String, FileFixtureStatistics)] = []
        var archive: ArchivePressureDiagnostics.Snapshot?
        model.archivePressureFactory = { ArchivePressureDiagnostics(recordingID: $0) }
        model.archivePressureWriter = { archive = $0 }
        model.fileFixtureStatisticsWriter = { id, stats in
            exports.append((id, stats))
            await gate.enter()
            throw CocoaError(.fileWriteUnknown)
        }
        await model.start()
        let id = try XCTUnwrap(model.currentCapture?.id)
        let deadline = ContinuousClock.now + .seconds(2)
        while source.statistics.videoFrames < 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(source.statistics.videoFrames, 3)
        let stopping = Task { await model.stop() }
        guard await gate.waitUntilEntered(timeout: .seconds(3)) else {
            await gate.release(); await stopping.value
            XCTFail("Joined statistics writer was not called"); return
        }
        XCTAssertEqual(model.state, .stopping)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(exports.first?.0, id)
        XCTAssertEqual(exports.first?.1, source.statistics)
        XCTAssertEqual(exports.first?.1.closed, true)
        XCTAssertEqual(archive?.recordingID, id)
        XCTAssertEqual(archive?.coverage.producer, true)
        XCTAssertEqual(archive?.coverage.session, true)
        XCTAssertEqual(archive?.coverage.persistence, true)
        await model.start()
        XCTAssertEqual(exports.count, 1)
        await gate.release(); await stopping.value
        XCTAssertEqual(model.state, .idle, "Diagnostic write failure must preserve successful recording")
        XCTAssertEqual(model.recordings.first?.status, .completed)
        await model.stop()
        XCTAssertEqual(exports.count, 1)
    }

    func testFileStatisticsEncodingRequiresClosureAndPreservesExactCounters() throws {
        var stats = FileFixtureStatistics()
        XCTAssertThrowsError(try FileFixtureDiagnostics.data(recordingID: "recording", statistics: stats))
        stats.closed = true
        stats.videoFrames = 9_007_199_254_740_993
        stats.audioSamples = 19_200
        stats.audioBuffers = 12
        stats.readCalls = 25
        stats.totalReadSeconds = 0.02
        stats.maximumReadSeconds = 0.01
        stats.maximumSourceLagSeconds = 0.2
        stats.firstVideoDeliverySeconds = 0.01
        stats.lastVideoDeliverySeconds = 0.4
        XCTAssertThrowsError(try FileFixtureDiagnostics.data(recordingID: "", statistics: stats))
        let data = try FileFixtureDiagnostics.data(recordingID: "recording", statistics: stats)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["recordingID"] as? String, "recording")
        let value = try XCTUnwrap(object["statistics"] as? [String: Any])
        XCTAssertEqual(value["videoFrames"] as? String, "9007199254740993")
        XCTAssertEqual(value["audioSamples"] as? String, "19200")
        XCTAssertEqual(value["readCalls"] as? String, "25")
        XCTAssertEqual(value["audioBuffers"] as? String, "12")
        XCTAssertEqual(value["closed"] as? Bool, true)
        XCTAssertEqual(value["maximumSourceLagSeconds"] as? Double, 0.2)
        XCTAssertEqual(value["totalReadSeconds"] as? Double, 0.02)
        XCTAssertEqual(value["firstVideoDeliverySeconds"] as? Double, 0.01)
    }

    func testFileDiagnosticsBracketVideoPreparationAndCloseOnlyAfterJoinedStop() async throws {
        let movie = try await FileSourceTestMovie.make()
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let diagnostics = ArchivePressureDiagnostics(recordingID: "file-hooks")
        XCTAssertTrue(source.attachArchivePressureDiagnostics(diagnostics))
        let other = ArchivePressureDiagnostics(recordingID: "other")
        XCTAssertFalse(source.attachArchivePressureDiagnostics(other))
        XCTAssertFalse(other.snapshot.coverage.producer)
        let delivered = FileSourceLedger(), ended = expectation(description: "File complete")
        _ = try await source.prepare(callbacks: .init(sample: { sample in
            delivered.append(sample)
            let active = diagnostics.snapshot.observations.activeProducer
            if sample.kind == .video {
                XCTAssertEqual(active?.frameIndex, String(delivered.videoCount - 1))
                XCTAssertNotNil(active?.generationEnd)
                XCTAssertNotNil(active?.callbackStart)
                XCTAssertNil(active?.callbackEnd)
            } else { XCTAssertNil(active) }
        }, event: { _ in ended.fulfill() }))
        XCTAssertFalse(source.attachArchivePressureDiagnostics(other))
        try await source.start()
        await fulfillment(of: [ended], timeout: 4)
        XCTAssertFalse(source.statistics.closed)
        await source.stop()
        let stats = source.statistics
        XCTAssertTrue(stats.closed)
        XCTAssertEqual(stats.videoFrames, 12)
        XCTAssertEqual(stats.audioSamples, 19_200)
        XCTAssertEqual(stats.audioBuffers, Int64(delivered.rows.filter { $0.kind == .audio }.count))
        XCTAssertEqual(stats.readCalls, stats.videoFrames + stats.audioBuffers + 1)
        XCTAssertGreaterThanOrEqual(stats.totalReadSeconds, stats.maximumReadSeconds)
        XCTAssertGreaterThan(stats.maximumReadSeconds, 0)
        XCTAssertGreaterThan(try XCTUnwrap(stats.lastVideoDeliverySeconds), try XCTUnwrap(stats.firstVideoDeliverySeconds))
        let snapshot = diagnostics.snapshot
        XCTAssertTrue(snapshot.coverage.producer)
        XCTAssertTrue(snapshot.validity.timingValid)
        XCTAssertFalse(snapshot.validity.invalidSequence)
        XCTAssertNil(snapshot.observations.activeProducer)
        let spans = snapshot.observations.producers.completed
        XCTAssertEqual(spans.map(\.frameIndex), (0..<12).map(String.init))
        for span in spans {
            XCTAssertLessThanOrEqual(try XCTUnwrap(span.generationStart), try XCTUnwrap(span.generationEnd))
            XCTAssertLessThanOrEqual(try XCTUnwrap(span.generationEnd), try XCTUnwrap(span.callbackStart))
            XCTAssertLessThanOrEqual(try XCTUnwrap(span.callbackStart), try XCTUnwrap(span.callbackEnd))
            XCTAssertNotNil(span.nominalDeadline)
        }
        await source.stop()
        XCTAssertEqual(source.statistics, stats)
    }

    func testPreparedSourceIsSilentThenPreservesDecodedMediaAndInterruptsAtEOF() async throws {
        let movie = try await FileSourceTestMovie.make()
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let ledger = FileSourceLedger()
        let ended = expectation(description: "Finite source exhausted")
        let origin = try await source.prepare(callbacks: .init(sample: { ledger.append($0) }, event: {
            ledger.event($0); ended.fulfill()
        }))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(ledger.rows.count, 0)
        XCTAssertEqual(source.statistics.videoFrames, 0)
        try await source.start()
        await fulfillment(of: [ended], timeout: 4)
        await source.stop()
        let rows = ledger.rows
        let video = rows.filter { $0.kind == .video }
        XCTAssertEqual(video.count, 12)
        XCTAssertEqual(rows.filter { $0.kind == .audio }.reduce(0) { $0 + $1.samples }, 19_200)
        for pair in zip(rows, rows.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.pts, pair.1.pts) }
        for (index, row) in video.enumerated() {
            XCTAssertEqual(row.pts - origin.seconds, Double(index) / 30, accuracy: 0.000_002)
            XCTAssertFalse(row.mainThread)
        }
        XCTAssertEqual(ledger.events, [.interrupted])
        XCTAssertEqual(source.statistics.videoFrames, 12)
        XCTAssertEqual(source.statistics.audioSamples, 19_200)
        let audio = rows.filter { $0.kind == .audio }
        var audioSamples = 0
        for row in audio {
            XCTAssertLessThanOrEqual(row.samples, 1600, "Pacing must not send over one video period of future audio")
            XCTAssertEqual(row.pts - origin.seconds, Double(audioSamples) / 48_000, accuracy: 0.000_002)
            audioSamples += row.samples
        }
        let expected = (0..<19_200).map { FixtureCameraSource.markerPCM(at: Double($0) / 48_000) }
        XCTAssertEqual(ledger.audioPCM, expected.withUnsafeBytes { Data($0) }, "Splitting must preserve every PCM value")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(video.last).wall - XCTUnwrap(video.first).wall, 0.33)
        do { try await source.start(); XCTFail("One-use source restarted") } catch {}
        do { _ = try await source.prepare(callbacks: .init(sample: { _ in }, event: { _ in })); XCTFail("Prepared twice") } catch {}
    }

    func testNonzeroAssetOriginDoesNotBecomeAPlaybackDelay() async throws {
        let movie = try await FileSourceTestMovie.make(offset: 2)
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let ledger = FileSourceLedger(), first = expectation(description: "First video immediately")
        let origin = try await source.prepare(callbacks: .init(sample: {
            ledger.append($0)
            if $0.kind == .video, ledger.videoCount == 1 { first.fulfill() }
        }, event: { ledger.event($0) }))
        XCTAssertEqual(origin.seconds, 2, accuracy: 0.000_002)
        try await source.start()
        await fulfillment(of: [first], timeout: 1)
        await source.stop()
        XCTAssertEqual(ledger.rows.first?.pts ?? -1, 2, accuracy: 0.000_002)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    func testIndependentTrackOriginsArePreservedWithoutSynthesizedLeadingVideo() async throws {
        let movie = try await FileSourceTestMovie.make(videoDelay: 0.1)
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let ledger = FileSourceLedger(), ended = expectation(description: "Offset tracks complete")
        let origin = try await source.prepare(callbacks: .init(sample: { ledger.append($0) }, event: {
            ledger.event($0); ended.fulfill()
        }))
        XCTAssertEqual(origin.seconds, 0, accuracy: 0.000_002)
        try await source.start()
        await fulfillment(of: [ended], timeout: 4)
        await source.stop()
        let videos = ledger.rows.filter { $0.kind == .video }
        XCTAssertEqual(videos.count, 12)
        XCTAssertEqual(try XCTUnwrap(videos.first).pts, 0.1, accuracy: 0.000_002)
        XCTAssertEqual(try XCTUnwrap(ledger.rows.first { $0.kind == .audio }).pts, 0, accuracy: 0.000_002)
        XCTAssertEqual(source.statistics.audioSamples, 19_200)
        XCTAssertEqual(ledger.events, [.interrupted])
    }

    func testCadenceKeepsNormalPhaseAndExposesDiscardedWakeBacklog() {
        let origin = ContinuousClock.now
        var cadence = FileFixtureCadence(origin: origin)
        cadence.began(sourceSeconds: 0, at: origin + .milliseconds(5))
        XCTAssertEqual(cadence.deadline(sourceSeconds: 1.0 / 30), origin + .seconds(1.0 / 30))
        let late = origin + .seconds(0.25)
        cadence.began(sourceSeconds: 1.0 / 30, at: late)
        XCTAssertEqual(cadence.deadline(sourceSeconds: 2.0 / 30), late + .seconds(1.0 / 30))
        XCTAssertEqual(cadence.nominalLag(sourceSeconds: 1.0 / 30, at: late), 0.25 - 1.0 / 30, accuracy: 1e-9)
    }

    func testStopDuringPacingJoinsCallbacksAndDoesNotReportFailure() async throws {
        let movie = try await FileSourceTestMovie.make(frames: 30)
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let ledger = FileSourceLedger(), delivered = expectation(description: "Two video frames")
        _ = try await source.prepare(callbacks: .init(sample: {
            ledger.append($0)
            if $0.kind == .video, ledger.videoCount == 2 { delivered.fulfill() }
        }, event: { ledger.event($0) }))
        try await source.start()
        await fulfillment(of: [delivered], timeout: 2)
        await source.stop()
        let count = ledger.rows.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ledger.rows.count, count)
        XCTAssertLessThan(ledger.videoCount, 30)
        let lastVideo = try XCTUnwrap(ledger.rows.last { $0.kind == .video })
        let lastAudio = try XCTUnwrap(ledger.rows.last { $0.kind == .audio })
        XCTAssertLessThanOrEqual(lastAudio.pts + Double(lastAudio.samples) / 48_000 - (lastVideo.pts + 1.0 / 30), 1.0 / 30 + 0.000_002)
        XCTAssertTrue(ledger.events.isEmpty)
        await source.stop()
    }

    func testStopWaitsForInFlightSampleCallback() async throws {
        let movie = try await FileSourceTestMovie.make()
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let gate = FileSourceCallbackGate()
        _ = try await source.prepare(callbacks: .init(sample: { sample in
            if sample.kind == .video { gate.blockOnce() }
        }, event: { _ in }))
        try await source.start()
        await fulfillment(of: [gate.entered], timeout: 2)
        let stopping = Task { await source.stop(); gate.didStop() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(gate.stopped)
        gate.release.signal()
        await stopping.value
        XCTAssertTrue(gate.stopped)
        XCTAssertFalse(gate.timedOut)
    }

    func testDelayedCallbackPreservesSamplesWithoutCatchUpBurstAndExposesLag() async throws {
        let movie = try await FileSourceTestMovie.make()
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let ledger = FileSourceLedger(), ended = expectation(description: "End after delayed delivery")
        _ = try await source.prepare(callbacks: .init(sample: {
            ledger.append($0)
            if $0.kind == .video, ledger.videoCount == 1 { Thread.sleep(forTimeInterval: 0.2) }
        }, event: { ledger.event($0); ended.fulfill() }))
        try await source.start()
        await fulfillment(of: [ended], timeout: 4)
        await source.stop()
        let times = ledger.rows.filter { $0.kind == .video }.map(\.wall)
        XCTAssertEqual(times.count, 12)
        for t in times { XCTAssertLessThanOrEqual(times.filter { $0 >= t && $0 < t + 0.01 }.count, 2) }
        XCTAssertGreaterThan(source.statistics.maximumSourceLagSeconds, 0.15)
        XCTAssertEqual(source.statistics.audioSamples, 19_200)
    }

    func testMissingAudioAndCorruptOrNonlocalInputsFailPreparation() async throws {
        let movie = try await FileSourceTestMovie.make(audio: false)
        defer { movie.remove() }
        let corrupt = movie.root.appendingPathComponent("corrupt.mov")
        try Data("not a movie".utf8).write(to: corrupt)
        for url in [movie.url, corrupt, movie.root, URL(string: "https://example.invalid/fixture.mov")!] {
            let source = FileFixtureCameraSource(url: url, profile: profile)
            let ledger = FileSourceLedger()
            do {
                _ = try await source.prepare(callbacks: .init(sample: { ledger.append($0) }, event: { ledger.event($0) }))
                XCTFail("Invalid input accepted")
            } catch {}
            await source.stop()
            XCTAssertEqual(ledger.rows.count, 0)
            XCTAssertEqual(ledger.events, [.failed])
        }
    }

    func testUnsupportedProfileAndMismatchedGeometryFailBeforeDelivery() async throws {
        let movie = try await FileSourceTestMovie.make()
        defer { movie.remove() }
        for profile in [ArchiveProfile(), ArchiveProfile(width: 320, height: 240, framesPerSecond: 60)] {
            let source = FileFixtureCameraSource(url: movie.url, profile: profile)
            do {
                _ = try await source.prepare(callbacks: .init(sample: { _ in XCTFail("Unexpected sample") }, event: { _ in }))
                XCTFail("Unsupported source accepted")
            } catch {}
            await source.stop()
        }
    }

    func testAdapterRecordsThroughNativeArchiveUntilExplicitStop() async throws {
        let movie = try await FileSourceTestMovie.make(frames: 60)
        defer { movie.remove() }
        let source = FileFixtureCameraSource(url: movie.url, profile: profile)
        let writer = try SegmentedArchiveWriter(directory: movie.root.appendingPathComponent("archive"), profile: profile)
        let session = try RecordingSession(sink: SegmentedArchiveSink(writer: writer))
        let recording = CaptureRecording(source: source, session: session)
        try await recording.start()
        try await Task.sleep(for: .milliseconds(450))
        let recovered = try await recording.stop()
        let export = try await ArchiveExporter().export(recovered, to: movie.root.appendingPathComponent("export.mp4"))
        XCTAssertGreaterThanOrEqual(export.videoFrames, 10)
        XCTAssertLessThan(export.videoFrames, 60)
        XCTAssertEqual(export.videoFrames, source.statistics.videoFrames)
        XCTAssertEqual(session.snapshot.state, .finished)
        XCTAssertNil(session.snapshot.failure)
        XCTAssertEqual(session.snapshot.queue.droppedCount, 0)
        XCTAssertEqual(session.snapshot.queue.rejectedCount, 0)
    }
}

private final class FileSourceLedger: @unchecked Sendable {
    struct Row { let kind: CapturedMediaSample.Kind; let pts: Double; let samples: Int; let wall: Double; let mainThread: Bool }
    private let lock = NSLock()
    private var stored: [Row] = []
    private var notices: [CaptureSourceEvent] = []
    private var pcm = Data()
    var audioPCM: Data { lock.withLock { pcm } }
    var rows: [Row] { lock.withLock { stored } }
    var videoCount: Int { lock.withLock { stored.filter { $0.kind == .video }.count } }
    var events: [CaptureSourceEvent] { lock.withLock { notices } }
    func append(_ sample: CapturedMediaSample) {
        lock.withLock {
            stored.append(.init(kind: sample.kind, pts: sample.sampleBuffer.presentationTimeStamp.seconds,
                samples: sample.sampleBuffer.numSamples, wall: ProcessInfo.processInfo.systemUptime, mainThread: Thread.isMainThread))
            if sample.kind == .audio, let block = sample.sampleBuffer.dataBuffer {
                var bytes = Data(count: sample.sampleBuffer.numSamples * 2)
                let count = bytes.count
                let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
                XCTAssertEqual(status, noErr)
                pcm.append(bytes)
            }
        }
    }
    func event(_ event: CaptureSourceEvent) { lock.withLock { notices.append(event) } }
}

private final class FileSourceCallbackGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Callback blocked")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false, stop = false, timeout = false
    var stopped: Bool { lock.withLock { stop } }
    var timedOut: Bool { lock.withLock { timeout } }
    func didStop() { lock.withLock { stop = true } }
    func blockOnce() {
        guard lock.withLock({ if used { return false }; used = true; return true }) else { return }
        entered.fulfill()
        if release.wait(timeout: .now() + 3) == .timedOut { lock.withLock { timeout = true } }
    }
}

private struct FileSourceTestMovie {
    let root: URL
    var url: URL { root.appendingPathComponent("source.mov") }
    func remove() { try? FileManager.default.removeItem(at: root) }
    static func make(frames: Int = 12, audio: Bool = true, offset: Double = 0, videoDelay: Double = 0) async throws -> Self {
        let movie = Self(root: testRecordingRoot())
        try FileManager.default.createDirectory(at: movie.root, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { movie.remove() } }
        let writer = try AVAssetWriter(outputURL: movie.url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoExpectedSourceFrameRateKey: 30]])
        let pcm = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        video.expectsMediaDataInRealTime = true
        pcm.expectsMediaDataInRealTime = true
        writer.add(video)
        if audio { writer.add(pcm) }
        let done = XCTestExpectation(description: "Generated local fixture")
        let state = FileSourceWriterState()
        let generator = FixtureCameraSource(profile: .init(width: 320, height: 240), failAfterFrames: frames)
        let origin = try await generator.prepare(callbacks: .init(sample: { sample in
            let input = sample.kind == .video ? video : pcm
            if sample.kind == .audio && !audio { return }
            // Offline fixture preparation must respect writer backpressure rather
            // than omit a source sample when an encoder warms up.
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !input.isReadyForMoreMediaData { state.failed("writer readiness deadline: \(sample.kind), PTS \(sample.sampleBuffer.presentationTimeStamp.seconds), writer state \(writer.status.rawValue)") }
            else {
                var buffer = sample.sampleBuffer
                if sample.kind == .video && videoDelay != 0 {
                    var timing = CMSampleTimingInfo(duration: buffer.duration,
                        presentationTimeStamp: buffer.presentationTimeStamp + CMTime(seconds: videoDelay, preferredTimescale: 600),
                        decodeTimeStamp: .invalid)
                    var shifted: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted) != noErr || shifted == nil {
                        state.failed("retiming failed"); return
                    }
                    buffer = shifted!
                }
                if !input.append(buffer) { state.failed("writer append rejected: \(sample.kind)") }
            }
        }, event: { _ in done.fulfill() }))
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: origin - CMTime(seconds: offset, preferredTimescale: 60))
        try await generator.start()
        let generated = await XCTWaiter.fulfillment(of: [done], timeout: 6)
        await generator.stop()
        XCTAssertEqual(generated, .completed)
        video.markAsFinished()
        if audio { pcm.markAsFinished() }
        await writer.finishWriting()
        XCTAssertNil(state.failure)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        completed = true
        return movie
    }
}
private final class FileSourceWriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var failure: String? { lock.withLock { value } }
    func failed(_ reason: String) { lock.withLock { if value == nil { value = reason } } }
}
