import AVFoundation
import Foundation
@testable import HaishinKit
import Testing
@testable import SRTHaishinKit

@Suite(.serialized) struct SRTStreamFinishTests {
    @Test func pacingQueueKeepsAnExplicitCountAndByteBoundAndCannotChangeWhileRunning() {
        let codec = VideoCodec(), outgoing: OutgoingStream
        outgoing = OutgoingStream(videoCodec: codec)
        #expect(codec.outputLimits.count == 8)
        #expect(outgoing.enablePacedVideoOutput())
        #expect(codec.outputLimits.count == 16)
        #expect(codec.outputLimits.bytesPerItem == 2 * 1024 * 1024)
        outgoing.startRunning()
        #expect(!outgoing.enablePacedVideoOutput())
        outgoing.stopRunning()
    }
    @Test func pacedFinishPreservesEveryTailFrameAtSourceCadence() async throws {
        let bytes = FinishBytes(), observed = PacedFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { bytes.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection, compressedVideoObserver: observed.record, pacesEncodedVideo: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setVideoInputBufferCounts(32)
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try finishVideo(0))
        let ready = ContinuousClock.now + .seconds(2)
        while observed.rows.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(observed.rows.count == 1)
        for frame in 1...12 { await stream.append(try finishVideo(frame)) }
        await stream.finish()
        let rows = observed.rows
        #expect(rows.count == 13)
        let expectedPTS: [Int64] = (0...12).map { 9000 + Int64($0) * 3000 }
        #expect(bytes.videoPTS == expectedPTS)
        #expect(await stream.publishingError == nil)
        for row in rows {
            #expect(row.at >= row.frame.dequeuedAt)
            #expect(row.frame.sourceCadencePaced)
            #expect(row.at - rows[0].at >= row.frame.sourcePTS.seconds - 0.005)
        }
        #expect(rows.contains { $0.at - $0.frame.dequeuedAt > 0.01 })
        await connection.close()
    }
    @Test func closeCancelsWaitingPacerAndNewPublicationHasFreshAnchor() async throws {
        let gate = PacingWaitGate(), observed = PacedFrames()
        let codec = VideoCodec()
        let outgoing = OutgoingStream(videoCodec: codec)
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: outgoing, compressedVideoObserver: observed.record,
            pacesEncodedVideo: true, pacingSleep: gate.wait)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try finishVideo(0))
        let ready = ContinuousClock.now + .seconds(2)
        while observed.rows.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(observed.rows.count == 1)
        await stream.append(try finishVideo(15))
        let finishing = Task { await stream.finish() }
        let waiting = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < waiting { await Task.yield() }
        try #require(gate.entered)
        await stream.close(); await finishing.value
        #expect(observed.rows.count == 1)
        #expect(gate.cancelled)
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try finishVideo(100))
        await stream.finish()
        #expect(observed.rows.count == 2)
        #expect(observed.rows.last?.frame.sourcePTS == CMTime(value: 100, timescale: 30))
        #expect(observed.rows.first?.frame.publishingGeneration != observed.rows.last?.frame.publishingGeneration)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }
    @Test(arguments: ["deadline", "overflow"])
    func pacedConsumerWaitCannotEvadeFinishDeadlineOrQueueBound(mode: String) async throws {
        let gate = PacingWaitGate(), observed = PacedFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), compressedVideoObserver: observed.record,
            pacesEncodedVideo: true, pacingSleep: gate.wait)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setVideoInputBufferCounts(32)
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try finishVideo(0))
        let ready = ContinuousClock.now + .seconds(2)
        while observed.rows.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(observed.rows.count == 1)
        for frame in 1...(mode == "overflow" ? 24 : 1) { await stream.append(try finishVideo(frame)) }
        await stream.finish(timeout: mode == "deadline" ? .milliseconds(80) : .seconds(2))
        #expect(gate.entered && gate.cancelled)
        #expect(observed.rows.count == 1)
        let error = await stream.publishingError
        #expect(error == (mode == "deadline" ? .outputTerminated(boundary: "SRT finish deadline") : .queueCapacityExceeded(boundary: "video codec")))
        #expect(await stream.readyState == .idle)
        await connection.close()
    }
    @Test func verifiedBitRateRequiresCurrentRawEncoderAndPreservesFinalFrames() async throws {
        let bytes = FinishBytes()
        let formats = FinishFormats()
        let connection = SRTConnection(socket: SRTSocket(sender: { bytes.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection, compressedVideoObserver: formats.record)
        await connection.addStream(stream)
        #expect(await stream.publishingGeneration == nil)
        await #expect(throws: VideoBitRateUpdateError.notEncoding) {
            try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: 0)
        }
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await #expect(throws: VideoBitRateUpdateError.notEncoding) {
            try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: generation)
        }
        await stream.append(try finishVideo(0))
        let deadline = ContinuousClock.now + .seconds(2)
        while bytes.videoPTS.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(bytes.videoPTS == [9000])
        let updated = try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: generation)
        #expect(updated.bitRate == 1_000_000)
        #expect(await stream.videoSettings.bitRate == 1_000_000)
        for frame in 1...4 { await stream.append(try finishVideo(frame)) }
        await stream.finish()
        #expect(bytes.videoPTS == [9000, 12000, 15000, 18000, 21000])
        #expect(formats.frames.count == 5)
        #expect(formats.frames.allSatisfy { $0.valid && $0.wasEncoded && $0.width == 64 && $0.height == 64 && $0.publishingGeneration == generation })
        #expect(formats.frames.map(\.sourcePTS) == (0...4).map { CMTime(value: Int64($0), timescale: 30) })
        #expect(await stream.publishingError == nil)
        #expect(await stream.publishingGeneration == nil)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration != generation)
        await #expect(throws: VideoBitRateUpdateError.notEncoding) {
            try await stream.setVerifiedVideoBitRate(2_000_000, publishingGeneration: generation)
        }
        await connection.close()
    }

    @Test func compressedPassthroughCannotUpdateAnEarlierRawEncoder() async throws {
        let codec = VideoCodec()
        codec.settings = .init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false)
        let output = codec.outputStream
        codec.startRunning(); codec.append(try finishVideo(1))
        let complete = codec.makeCompletion()
        await Task.detached { complete() }.value
        codec.stopRunning()
        var iterator = output.makeAsyncIterator()
        let compressed = try #require(await iterator.next())

        let bytes = FinishBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { bytes.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try finishVideo(0))
        let deadline = ContinuousClock.now + .seconds(2)
        while bytes.videoPTS.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(bytes.videoPTS == [9000])
        await stream.append(compressed)
        #expect(await stream.publishingError == nil)
        #expect(await stream.muxerError == nil)
        await #expect(throws: VideoBitRateUpdateError.notEncoding) {
            try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: generation)
        }
        #expect(await stream.videoSettings.bitRate == 640_000)
        await stream.finish(); await connection.close()
    }

    @Test func finishingRejectsVerifiedUpdateBeforeClosingTheStream() async throws {
        let peer = FinishBlockedPeer()
        let connection = SRTConnection(socket: SRTSocket(sender: { peer.send($0) }))
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try finishVideo(0))
        let enteredDeadline = ContinuousClock.now + .seconds(2)
        while !peer.entered && ContinuousClock.now < enteredDeadline { await Task.yield() }
        #expect(peer.entered)
        #expect(await stream.transportClockSnapshot?.publishingGeneration == generation)
        _ = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        #expect(await stream.verifiedVideoBitRateReceipt != nil)
        let finishing = Task { await stream.finish() }
        let finishDeadline = ContinuousClock.now + .seconds(2)
        while await stream.publishingGeneration != nil, ContinuousClock.now < finishDeadline { await Task.yield() }
        #expect(await stream.readyState == .publishing)
        #expect(await stream.transportClockSnapshot == nil)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        await #expect(throws: VideoBitRateUpdateError.notEncoding) {
            try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: generation)
        }
        peer.release(); await finishing.value
        await connection.close()
    }

    @Test func constructionObserverReachesNativeEncoderThroughFinalDrain() async throws {
        let recorder = FinishEncoderObserver()
        let bytes = FinishBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { bytes.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection, encoderCompletionObserver: recorder.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setVideoInputBufferCounts(4)
        await stream.setExpectedMedias([.video])
        await stream.publish()
        #expect(recorder.sourcePTS.isEmpty)
        for frame in 0..<3 { await stream.append(try finishVideo(frame)) }
        await stream.finish()
        #expect(recorder.sourcePTS == (0..<3).map { CMTime(value: Int64($0), timescale: 30) })
        #expect(bytes.videoPTS == [9000, 12000, 15000])
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test func finishPreservesLastAcceptedVideoThroughTransport() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: { bytes.append($0); return Int32($0.count) })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setVideoInputBufferCounts(4)
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try finishVideo(0))
        let firstDeadline = ContinuousClock.now + .seconds(2)
        while bytes.videoPTS.isEmpty && ContinuousClock.now < firstDeadline { await Task.yield() }
        #expect(bytes.videoPTS.first == 9000)
        for frame in 1...4 { await stream.append(try finishVideo(frame)) }
        // Finishing must preserve the async raw/VT/TS tail, not cancel its consumers.
        await stream.finish()
        #expect(await stream.publishingError == nil)
        let emitted = bytes.videoPTS
        #expect(emitted == [9000, 12000, 15000, 18000, 21000])
        #expect(await stream.readyState == .idle)
        let count = bytes.count
        await stream.append(try finishVideo(5))
        await stream.finish()
        #expect(bytes.count == count, "Late input or repeated finish must not resurrect publication")
        await connection.close()
    }

    @Test func finishFailsWhenExpectedTrackNeverArrives() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: { bytes.append($0); return Int32($0.count) })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video, .audio])
        await stream.publish()
        await stream.append(try finishVideo(0))
        await stream.finish()
        #expect(await stream.publishingError == .muxerFailed(reason: "incompleteStartup"))
        #expect(bytes.videoPTS.isEmpty)
        #expect(await stream.readyState == .idle)
        await connection.close()
    }

    @Test func concurrentFinishWaitersJoinDespiteCallerCancellation() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: { bytes.append($0); return Int32($0.count) })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try finishVideo(0))
        let first = Task { await stream.finish() }
        first.cancel()
        let second = Task { await stream.finish() }
        await first.value
        await second.value
        #expect(bytes.videoPTS == [9000])
        #expect(await stream.publishingError == nil)
        #expect(await stream.readyState == .idle)
        await connection.close()
    }

    @Test func joiningFinishCallerCanImmediatelyRepublish() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: {
            bytes.append($0)
            Thread.sleep(forTimeInterval: 0.02)
            return Int32($0.count)
        })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try finishVideo(0))
        let original = Task(priority: .background) { await stream.finish() }
        let deadline = ContinuousClock.now + .seconds(2)
        while bytes.count == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(bytes.count > 0)
        // Transport is still in its finite send. This caller joins the owned
        // finish, then reuses the stream without waiting for the original caller.
        let joining = Task(priority: .userInitiated) {
            await stream.finish()
            await stream.setExpectedMedias([.video])
            await stream.publish()
            return await stream.readyState
        }
        #expect(await joining.value == .publishing)
        await original.value
        await connection.close()
    }

    @Test func immediateCloseDuringFinishCannotResumePublication() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: {
            bytes.append($0)
            Thread.sleep(forTimeInterval: 0.02)
            return Int32($0.count)
        })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try finishVideo(0))
        let finishing = Task { await stream.finish() }
        let deadline = ContinuousClock.now + .seconds(2)
        while bytes.count == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(bytes.count > 0)
        await stream.close()
        await finishing.value
        let count = bytes.count
        await stream.append(try finishVideo(1))
        #expect(bytes.count == count)
        #expect(await stream.readyState == .idle)
        await connection.close()
    }

    @Test func finishDeadlineAbortsSlowPeerAndRejectsLateInput() async throws {
        let bytes = FinishBytes()
        let socket = SRTSocket(sender: {
            bytes.append($0)
            Thread.sleep(forTimeInterval: 0.05) // Model a finite blocking libsrt call.
            return Int32($0.count)
        })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try finishVideo(0))
        let entered = ContinuousClock.now + .seconds(2)
        while bytes.count == 0 && ContinuousClock.now < entered { await Task.yield() }
        #expect(bytes.count > 0)
        let started = ContinuousClock.now
        await stream.finish(timeout: .milliseconds(1))
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await stream.publishingError != nil)
        #expect(await stream.readyState == .idle)
        let count = bytes.count
        await stream.append(try finishVideo(1))
        #expect(bytes.count == count)
        await connection.close()
    }
}

private final class FinishBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var count: Int { lock.withLock { data.count } }
    func append(_ bytes: Data) { lock.withLock { data.append(bytes) } }
    var videoPTS: [Int64] {
        let snapshot = lock.withLock { data }
        return stride(from: 0, to: snapshot.count - snapshot.count % 188, by: 188).compactMap { offset in
            guard let packet = TSPacket(data: snapshot.subdata(in: offset..<offset + 188)),
                  packet.pid == TSWriter.defaultVideoPID, packet.payloadUnitStartIndicator,
                  packet.payload.count >= 14 else { return nil }
            let b = Array(packet.payload.dropFirst(9).prefix(5))
            return Int64(b[0] & 14) << 29 | Int64(b[1]) << 22 | Int64(b[2] & 254) << 14 | Int64(b[3]) << 7 | Int64(b[4]) >> 1
        }
    }
}

private func finishVideo(_ frame: Int) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let image = try #require(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    if let bytes = CVPixelBufferGetBaseAddress(image) { memset(bytes, Int32(frame), CVPixelBufferGetDataSize(image)) }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private final class FinishEncoderObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CMTime] = []
    var sourcePTS: [CMTime] { lock.withLock { stored } }
    func record(_ source: CMTime, _ output: CMTime) {
        #expect(CMTimeCompare(source, output) == 0)
        lock.withLock { stored.append(source) }
    }
}

private final class FinishBlockedPeer: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func send(_ data: Data) -> Int32 {
        let first = lock.withLock { let first = !didEnter; didEnter = true; return first }
        if first { _ = gate.wait(timeout: .now() + 1) }
        return Int32(data.count)
    }
    func release() { gate.signal() }
}

private final class FinishFormats: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SRTStream.CompressedVideoFrame] = []
    func record(_ value: SRTStream.CompressedVideoFrame) { lock.withLock { values.append(value) } }
    var frames: [SRTStream.CompressedVideoFrame] { lock.withLock { values } }
}

private final class PacedFrames: @unchecked Sendable {
    struct Row { let frame: SRTStream.CompressedVideoFrame; let at: Double }
    private let lock = NSLock()
    private var values: [Row] = []
    func record(_ frame: SRTStream.CompressedVideoFrame) {
        lock.withLock { values.append(.init(frame: frame, at: ProcessInfo.processInfo.systemUptime)) }
    }
    var rows: [Row] { lock.withLock { values } }
}
private final class PacingWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false, didCancel = false
    var entered: Bool { lock.withLock { didEnter } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func wait(_ delay: Double) async throws {
        lock.withLock { didEnter = true }
        do { try await Task.sleep(for: .seconds(5)) }
        catch { lock.withLock { didCancel = true }; throw error }
    }
}
