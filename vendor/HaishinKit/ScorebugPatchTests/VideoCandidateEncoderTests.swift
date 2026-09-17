import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct VideoCandidateEncoderTests {
    private var settings: VideoCodecSettings {
        .init(videoSize: CGSize(width: 32, height: 32), bitRate: 500_000,
              profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String, allowFrameReordering: false)
    }

    @Test func explicitStartAndSingleUseTerminalIdentity() async throws {
        let session = CandidateSession(), id = UUID()
        let encoder = try VideoCandidateEncoder(settings: settings, id: id, sessionFactory: { _, _ in session })
        #expect(!encoder.offer(try raw(.zero)))
        let sample = try raw(.zero), pixel = try #require(sample.imageBuffer)
        try await encoder.start()
        let beforeOffer = ProcessInfo.processInfo.systemUptime
        #expect(encoder.offer(sample))
        let afterOffer = ProcessInfo.processInfo.systemUptime
        let result = await encoder.finish()
        #expect(result.id == id && result.outcome == .completed)
        #expect(result.acceptedInputCount == 1 && result.outputCount == 1 && result.frames.count == 1)
        #expect(result.frames.first?.byteCount == 8 && result.frames.first?.isSync == true)
        #expect(result.frames.first?.width == 32 && result.frames.first?.height == 32)
        #expect(result.frames.first?.encoderSessionID == result.encoderSessionID)
        let frame = try #require(result.frames.first)
        #expect(frame.admittedAt >= beforeOffer && frame.admittedAt <= afterOffer)
        #expect(frame.admittedAt <= frame.submittedAt)
        #expect(frame.rawByteCount == CVPixelBufferGetDataSize(pixel))
        #expect(result.settings.bitRate == settings.bitRate)
        #expect(result.failure == nil && result.nativeFailure == nil)
        #expect(!encoder.offer(try raw(CMTime(value: 1, timescale: 30))))
        await #expect(throws: (any Error).self) { try await encoder.start() }
        #expect(await encoder.finish().outcome == .completed)
        #expect(session.events == ["submit", "complete", "invalidate"])
    }

    @Test func terminalBeforeStartCannotCreateAnEncoder() async throws {
        let session = CandidateSession()
        let unfinished = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        #expect(await unfinished.finish().outcome == .failed)
        await #expect(throws: (any Error).self) { try await unfinished.start() }
        let cancelled = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        #expect(await cancelled.cancel().outcome == .cancelled)
        #expect(await cancelled.finish().outcome == .cancelled)
        #expect(session.events.isEmpty)
    }

    @Test func cancelledStartupClosesAdmissionAndJoinsBeforeThrowing() async throws {
        let gate = CandidateGate(), session = CandidateSession()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        let starting = Task {
            await gate.waitUntilOpened()
            try await encoder.start()
        }
        starting.cancel()
        gate.open()
        await #expect(throws: (any Error).self) { try await starting.value }
        #expect(!encoder.offer(try raw(.zero)))
        #expect(await encoder.finish().outcome == .cancelled)
        #expect(session.events.isEmpty)
    }

    @Test func finishDrainsDelayedCallbacksAndCancellationJoinsTheSameOperation() async throws {
        let gate = CandidateGate(), session = CandidateSession(gate: gate)
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        let first = Task { await encoder.finish() }
        #expect(await gate.waitForEntry())
        #expect(!encoder.offer(try raw(CMTime(value: 1, timescale: 30))))
        let second = Task { await encoder.finish() }
        let cancellation = Task { await encoder.cancel() }
        // The finish cancellation handler is installed before native drain entry.
        // Cancelling that caller synchronously revokes success before gate release.
        first.cancel()
        #expect(session.events == ["submit", "complete"])
        gate.open()
        #expect(await first.value.outcome == .cancelled)
        #expect(await second.value.outcome == .cancelled)
        #expect(await cancellation.value.outcome == .cancelled)
        #expect(session.events == ["submit", "complete", "invalidate"])
    }

    @Test(arguments: [false, true])
    func unresolvedCountRejectsSeventeenthAfterIngressDrains(callbacksOnly: Bool) async throws {
        let session = CandidateSession(fault: "missingOutput", immediate: callbacksOnly)
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        do {
            for i in 0..<16 {
                try #require(encoder.offer(try raw(CMTime(value: Int64(i), timescale: 30))))
                try #require(await session.waitForSubmissions(i + 1))
            }
            if callbacksOnly { #expect(session.callbackCount == 16) }
            #expect(!encoder.offer(try raw(CMTime(value: 16, timescale: 30))))
            let result = await encoder.finish()
            #expect(result.outcome == .failed && result.acceptedInputCount == 16)
            #expect(result.failure == "unresolvedInputLimit")
        } catch {
            _ = await encoder.cancel()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func aggregateRawByteBoundIsIndependentOfCountAndCallbacks(callbacksOnly: Bool) async throws {
        let session = CandidateSession(fault: "missingOutput", immediate: callbacksOnly)
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        do {
            let first = try raw(.zero, size: 1600)
            let pixel = try #require(first.imageBuffer), bytes = CVPixelBufferGetDataSize(pixel)
            let capacity = (64 * 1024 * 1024) / bytes
            try #require(capacity > 4 && capacity < 16)
            for i in 0..<capacity {
                let sample = i == 0 ? first : try raw(CMTime(value: Int64(i), timescale: 30), size: 1600)
                try #require(encoder.offer(sample))
                try #require(await session.waitForSubmissions(i + 1))
            }
            if callbacksOnly { #expect(session.callbackCount == capacity) }
            #expect(!encoder.offer(try raw(CMTime(value: Int64(capacity), timescale: 30), size: 1600)))
            let result = await encoder.finish()
            #expect(result.outcome == .failed && result.acceptedInputCount == capacity)
            #expect(result.failure == "unresolvedRawByteLimit")
        } catch {
            _ = await encoder.cancel()
            throw error
        }
    }

    @Test(arguments: [64, 1600])
    func validatedDequeueRecyclesCountAndRawByteCredits(size: Int) async throws {
        let session = CandidateSession(), outputs = CandidateOutputs()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session },
            outputObserver: { _ in outputs.received() })
        try await encoder.start()
        do {
            let first = try raw(.zero, size: size)
            let bytes = CVPixelBufferGetDataSize(try #require(first.imageBuffer))
            let capacity = min(16, (64 * 1024 * 1024) / bytes)
            for i in 0..<capacity {
                let sample = i == 0 ? first : try raw(CMTime(value: Int64(i), timescale: 30), size: size)
                try #require(encoder.offer(sample))
                try #require(await session.waitForSubmissions(i + 1))
            }
            // Drain exactly one output and await its validated observer, avoiding a
            // fake burst through the independent eight-output compressed queue.
            #expect(session.releaseNext() == noErr)
            try #require(await outputs.wait(for: 1))
            try #require(encoder.offer(try raw(CMTime(value: Int64(capacity), timescale: 30), size: size)))
            try #require(await session.waitForSubmissions(capacity + 1))
            for i in 1...capacity {
                #expect(session.releaseNext() == noErr)
                try #require(await outputs.wait(for: i + 1))
            }
            let result = await encoder.finish()
            #expect(result.outcome == .completed)
            #expect(result.acceptedInputCount == capacity + 1 && result.outputCount == capacity + 1)
            #expect(result.frames.allSatisfy { $0.rawByteCount == bytes && $0.admittedAt <= $0.submittedAt })
        } catch {
            _ = await encoder.cancel()
            throw error
        }
    }

    @Test func rawIngressStillHoldsOnlyFourQueuedInputsWhileNativeAppendIsBlocked() async throws {
        let gate = CandidateGate(), session = CandidateSession(convertGate: gate)
        defer { gate.open() }
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        do {
            try #require(encoder.offer(try raw(.zero)))
            try #require(await gate.waitForEntry())
            for i in 1...4 { #expect(encoder.offer(try raw(CMTime(value: Int64(i), timescale: 30)))) }
            #expect(!encoder.offer(try raw(CMTime(value: 5, timescale: 30))))
            gate.open()
            let result = await encoder.finish()
            #expect(result.outcome == .failed && result.failure == "rawQueueFailure")
        } catch {
            gate.open()
            _ = await encoder.cancel()
            throw error
        }
    }

    @Test(arguments: ["compressed", "audio", "notReady", "negative", "epoch", "invalid", "duplicate", "backward", "format", "oversize", "span"])
    func rejectsMalformedOrUnboundedRawInput(fault: String) async throws {
        let session = CandidateSession(), encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        #expect(encoder.offer(try raw(CMTime(value: 1, timescale: 30))))
        let next: CMSampleBuffer
        switch fault {
        case "compressed": next = try candidateCompressed(CMTime(value: 2, timescale: 30))
        case "audio": next = try audio()
        case "notReady":
            next = try raw(CMTime(value: 2, timescale: 30))
            CMSampleBufferInvalidate(next)
        case "negative": next = try raw(CMTime(value: -1, timescale: 30))
        case "epoch": next = try raw(CMTime(value: 2, timescale: 30, flags: .valid, epoch: 1))
        case "invalid": next = try raw(.invalid)
        case "duplicate": next = try raw(CMTime(value: 2, timescale: 60))
        case "backward": next = try raw(.zero)
        case "format": next = try raw(CMTime(value: 2, timescale: 30), size: 48)
        case "oversize": next = try raw(CMTime(value: 2, timescale: 30), size: 2112)
        default: next = try raw(CMTime(value: 5, timescale: 1))
        }
        #expect(!encoder.offer(next))
        #expect(await encoder.finish().outcome == .failed)
    }

    @Test func admissionDeadlineRevokesEvidenceEvenWhenNoMoreFramesArrive() async throws {
        let gate = CandidateGate(), session = CandidateSession(), clock = CandidateClock()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session },
            now: { clock.now }, deadlineWait: { await gate.waitUntilOpened() })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        #expect(await session.wait(for: "submit"))
        clock.advance(9)
        gate.open()
        // No offer/finish/cancel triggers closure: the owned deadline must start
        // native draining independently, even when the caller goes idle.
        #expect(await session.wait(for: "complete"))
        #expect(await encoder.finish().outcome == .failed)
    }

    @Test(arguments: ["missingCallback", "duplicateCallback", "missingOutput", "duplicateOutput", "wrongDimensions", "notSync", "callbackMismatch", "oversizedOutput", "outputOverflow", "completionFailure", "convertFailure"])
    func rejectsUnreconciledOrInvalidNativeEvidence(fault: String) async throws {
        let session = CandidateSession(fault: fault), encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        let result = await encoder.finish()
        #expect(result.outcome == .failed)
        if fault == "completionFailure" { #expect(result.nativeFailure == .codecFailed(status: -77)) }
    }

    @Test func emptyRunHasNoSuccessfulPartialEvidence() async throws {
        let encoder = try VideoCandidateEncoder(settings: settings)
        try await encoder.start()
        #expect(await encoder.finish().outcome == .failed)
    }

    @Test func totalFrameLimitRemainsBoundedAfterEveryOutstandingCreditIsReleased() async throws {
        let session = CandidateSession(immediate: true), outputs = CandidateOutputs()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session },
            outputObserver: { _ in outputs.received() })
        try await encoder.start()
        for i in 0..<121 {
            #expect(encoder.offer(try raw(CMTime(value: Int64(i), timescale: 30))))
            #expect(await outputs.wait(for: i + 1))
        }
        #expect(!encoder.offer(try raw(CMTime(value: 121, timescale: 30))))
        let result = await encoder.finish()
        #expect(result.outcome == .failed && result.acceptedInputCount == 121 && result.outputCount == 121)
        #expect(result.frames.count == 121)
    }

    @Test func sessionReplacementCannotMixCandidateEvidence() async throws {
        let invalidator = CandidateInvalidator(), outputs = CandidateOutputs()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { mode, codec in
            guard case .compression = mode else { throw VTSessionError.failedToCreate(status: -91) }
            invalidator.install(codec)
            return CandidateSession(immediate: true)
        }, outputObserver: { _ in outputs.received() })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        #expect(await outputs.wait(for: 1))
        invalidator.invalidate()
        #expect(encoder.offer(try raw(CMTime(value: 1, timescale: 30))))
        #expect(await encoder.finish().outcome == .failed)
    }

    @Test func sessionCreationFailureIsRetainedThroughJoinedCleanup() async throws {
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in
            throw VTSessionError.failedToCreate(status: -91)
        })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        let result = await encoder.finish()
        #expect(result.outcome == .failed && result.nativeFailure == .codecFailed(status: -91))
    }

    @Test func rawAdmissionClockDeadlineDoesNotExpireAnAlreadyClosedNativeDrain() async throws {
        let gate = CandidateGate(), wake = CandidateGate(), session = CandidateSession(gate: gate), clock = CandidateClock()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session },
            now: { clock.now }, deadlineWait: { await wake.waitUntilOpened() })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        let finish = Task { await encoder.finish() }
        #expect(await gate.waitForEntry())
        clock.advance(9)
        wake.open()
        gate.open()
        #expect(await finish.value.outcome == .completed)
    }

    @Test func finishAfterAdmissionDeadlineCannotBeatADelayedTimer() async throws {
        let wake = CandidateGate(), clock = CandidateClock(), session = CandidateSession()
        let encoder = try VideoCandidateEncoder(settings: settings, sessionFactory: { _, _ in session },
            now: { clock.now }, deadlineWait: { await wake.waitUntilOpened() })
        try await encoder.start()
        #expect(encoder.offer(try raw(.zero)))
        clock.advance(9)
        // The timer is deliberately still suspended. finish must independently
        // enforce the admission deadline before it marks admission closed.
        let result = await encoder.finish()
        #expect(result.outcome == .failed && result.failure == "admissionDeadline")
    }

    @Test func realH264UsesRequestedScalingAndPreservesStartupKeyframe() async throws {
        let encoder = try VideoCandidateEncoder(settings: settings)
        try await encoder.start()
        for i in 0..<3 { #expect(encoder.offer(try raw(CMTime(value: Int64(i), timescale: 30)))) }
        let result = await encoder.finish()
        #expect(result.outcome == .completed)
        #expect(result.frames.count == 3 && result.frames.first?.isSync == true)
        #expect(result.frames.allSatisfy { $0.width == 32 && $0.height == 32 && $0.byteCount > 0 &&
            $0.submittedAt <= $0.completedAt && $0.completedAt <= $0.dequeuedAt })
        #expect(result.frames.map(\.sourcePTS) == (0..<3).map { CMTime(value: Int64($0), timescale: 30) })
    }

    private func raw(_ pts: CMTime, size: Int = 64) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let pixel = try #require(image)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let resolvedFormat = try #require(format)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: resolvedFormat, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func audio() throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

private final class CandidateOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func received() { lock.withLock { count += 1 } }
    func wait(for target: Int) async -> Bool {
        for _ in 0..<1000 {
            if lock.withLock({ count >= target }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private final class CandidateInvalidator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var codec: VideoCodec?
    func install(_ value: VideoCodec) { lock.withLock { codec = value } }
    func invalidate() { lock.withLock { codec?.requestSessionInvalidation() } }
}

private final class CandidateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset = 0.0
    var now: Double { lock.withLock { ProcessInfo.processInfo.systemUptime + offset } }
    func advance(_ delta: Double) { lock.withLock { offset += delta } }
}

private final class CandidateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false, opened = false
    func pause() {
        lock.withLock { entered = true }
        while !lock.withLock({ opened }) { Thread.sleep(forTimeInterval: 0.001) }
    }
    func open() { lock.withLock { opened = true } }
    func waitForEntry() async -> Bool {
        for _ in 0..<1000 {
            if lock.withLock({ entered }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
    func waitUntilOpened() async {
        while !lock.withLock({ opened }) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

private final class CandidateSession: VTSessionConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(CMTime, PublishingQueue<CMSampleBuffer>?, VideoEncoderCompletionObserver?)] = []
    private var log: [String] = []
    private var callbacks = 0
    private let gate: CandidateGate?
    private let convertGate: CandidateGate?
    private let fault: String?
    private let immediate: Bool
    init(gate: CandidateGate? = nil, fault: String? = nil, immediate: Bool = false, convertGate: CandidateGate? = nil) {
        self.gate = gate; self.fault = fault; self.immediate = immediate; self.convertGate = convertGate
    }
    var events: [String] { lock.withLock { log } }
    var callbackCount: Int { lock.withLock { callbacks } }
    func waitForSubmissions(_ count: Int) async -> Bool {
        for _ in 0..<1000 {
            if lock.withLock({ log.filter { $0 == "submit" }.count >= count && (!immediate || callbacks >= count) }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
    func releaseNext() -> OSStatus {
        let value = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        guard let (pts, output, callback) = value else { return -100 }
        return emit(pts, output, callback)
    }
    func wait(for event: String) async -> Bool {
        for _ in 0..<1000 {
            if events.contains(event) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
    func setOption(_ option: VTSessionOption) -> OSStatus { noErr }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
    func convert(_ sample: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        if fault == "convertFailure" { throw VTSessionError.failedToConvert(status: -92) }
        lock.withLock {
            log.append("submit")
            if !immediate { pending.append((sample.presentationTimeStamp, continuation, encoderCompletionObserver)) }
        }
        convertGate?.pause()
        if immediate { _ = emit(sample.presentationTimeStamp, continuation, encoderCompletionObserver) }
    }
    func completeFrames() -> OSStatus {
        let values = lock.withLock { log.append("complete"); let p = pending; pending.removeAll(); return p }
        gate?.pause()
        for (pts, output, callback) in values {
            let status = emit(pts, output, callback)
            if status != noErr { return status }
        }
        return fault == "completionFailure" ? -77 : noErr
    }
    private func emit(_ pts: CMTime, _ output: PublishingQueue<CMSampleBuffer>?, _ callback: VideoEncoderCompletionObserver?) -> OSStatus {
        let resultPTS = fault == "callbackMismatch" ? CMTime(value: 1, timescale: 1) : pts
        if fault != "missingCallback" {
            callback?(pts, resultPTS)
            lock.withLock { callbacks += 1 }
        }
        if fault == "duplicateCallback" { callback?(pts, resultPTS) }
        if fault == "missingOutput" { return noErr }
        do {
            let sample = try candidateCompressed(pts, width: fault == "wrongDimensions" ? 48 : 32,
                bytes: fault == "oversizedOutput" ? 2 * 1024 * 1024 + 1 : 8,
                sync: fault != "notSync")
            output?.yield(sample, byteCount: CMSampleBufferGetTotalSampleSize(sample))
            if fault == "duplicateOutput" { output?.yield(sample, byteCount: 8) }
            if fault == "outputOverflow" { for _ in 0..<12 { output?.yield(sample, byteCount: 8) } }
        } catch { return -99 }
        return noErr
    }
    func invalidate() { lock.withLock { log.append("invalidate"); pending.removeAll() } }
}

private func candidateCompressed(_ pts: CMTime, width: Int32 = 32, bytes: Int = 8, sync: Bool = true) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: width, height: 32, extensions: nil, formatDescriptionOut: &format) == noErr)
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var count = bytes, sample: CMSampleBuffer?
    let resolvedFormat = try #require(format)
    #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: resolvedFormat, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &count, sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    result.isNotSync = !sync
    return result
}
