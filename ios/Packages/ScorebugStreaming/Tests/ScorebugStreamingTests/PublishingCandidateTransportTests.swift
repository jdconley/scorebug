import AVFoundation
import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

@MainActor
final class PublishingCandidateTransportTests: XCTestCase {
    private func scope() -> VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 7,
              publishingAttemptID: UUID(), appliedProfileRevision: 11)
    }
    private func owner(clock: TransportTestClock = .init(), timer: TransportTestTimer = .init()) -> PublishingCandidateTransport {
        .init(scope: scope(), profile: .low240, now: { clock.now }, deadlineWait: { await timer.wait($0) })
    }
    private func prepare(_ owner: PublishingCandidateTransport) -> UUID {
        let id = UUID(); XCTAssertTrue(owner.bind(id: id)); XCTAssertTrue(owner.arm(publishingGeneration: 7)); return id
    }

    func testOpeningReadinessFloorIsImmutableAndOnlyDefersValidUnopenedWindow() async {
        let clock = TransportTestClock(), window = owner(clock: clock)
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(0)))
        prepare(window)
        XCTAssertTrue(window.isWaitingForOpeningAudio(at: pts(0)))
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: .invalid))
        window.observeAudio(audio(1, clock: clock))
        XCTAssertTrue(window.isWaitingForOpeningAudio(at: pts(0)))
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(1)))
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(2)))
        window.observeAudio(audio(2, clock: clock))
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(1)), "Later audio cannot move the floor")
        XCTAssertTrue(window.advanceRaw(pts(1)))
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(0)), "Opened windows never defer invalid later input")
        window.cancel()
        XCTAssertFalse(window.isWaitingForOpeningAudio(at: pts(0)))
        _ = await window.finish()
    }

    func testFailedOrCancelledOpeningCannotTurnIntoAnIndefiniteWait() async {
        let clock = TransportTestClock(), failed = owner(clock: clock), cancelled = owner(clock: clock)
        prepare(failed); prepare(cancelled)
        for n in 0...16 { failed.observeAudio(audio(n, clock: clock)) }
        XCTAssertFalse(failed.isWaitingForOpeningAudio(at: pts(0)))
        XCTAssertFalse(failed.advanceRaw(pts(0)))
        let result = await failed.finish()
        XCTAssertEqual(result.failure, "pendingAudioLimit")
        cancelled.cancel()
        XCTAssertFalse(cancelled.isWaitingForOpeningAudio(at: pts(0)))
        _ = await cancelled.finish()
    }

    func testAlignedAudioVideoProducesActualMuxCostAndImmutableReceipts() async throws {
        let clock = TransportTestClock(), window = owner(clock: clock)
        window.observeAudio(audio(0, clock: clock)) // ignored before campaign arming
        let id = prepare(window)
        XCTAssertTrue(window.advanceRaw(pts(0)))
        window.observeAudio(audio(0, clock: clock))
        window.observeAudio(audio(1, clock: clock)) // ahead, bounded pending
        XCTAssertTrue(window.observeVideo(try video(0)))
        clock.now = 10.1
        XCTAssertTrue(window.advanceRaw(pts(1)))
        XCTAssertTrue(window.observeVideo(try video(1)))
        window.closeRawWindow()
        clock.now = 10.2
        window.observeAudio(audio(2, clock: clock))
        let result = await window.finish()
        XCTAssertEqual(result.outcome, .completed, result.failure ?? "")
        XCTAssertEqual(result.id, id); XCTAssertEqual(result.publishingGeneration, 7)
        XCTAssertNil(result.openingAudioFailure)
        XCTAssertEqual(result.rawInputCount, 2); XCTAssertEqual(result.audio.count, 2)
        XCTAssertEqual(result.followingAudio?.sourcePTS, pts(2))
        XCTAssertEqual(result.maximumPendingCount, 1); XCTAssertEqual(result.maximumPendingBytes, 4)
        XCTAssertEqual(result.mux?.audioInputCount, 2); XCTAssertEqual(result.mux?.videoInputCount, 2)
        XCTAssertGreaterThan(result.mux?.transportBytes ?? 0, 20)
        XCTAssertEqual(result.mux?.inputs.filter { $0.media == .audio }.map(\.sourcePTS), result.audio.map(\.sourcePTS))
        let repeated = await window.finish()
        XCTAssertEqual(repeated.endedAt, result.endedAt)
        XCTAssertFalse(window.advanceRaw(pts(2)))
        XCTAssertFalse(window.observeVideo(try video(2)))
    }

    func testOneShotAudioBeforeFirstRawIsRetainedForItsSourceWindow() async throws {
        let clock = TransportTestClock(), window = owner(clock: clock)
        prepare(window)
        window.observeAudio(audio(0, clock: clock)) // before the eventual source anchor
        window.observeAudio(audio(1, clock: clock)) // one-shot opening packet
        clock.now = 10.01
        XCTAssertTrue(window.advanceRaw(pts(1)))
        XCTAssertTrue(window.observeVideo(try video(1, sync: true)))
        window.observeAudio(audio(2, clock: clock))
        clock.now = 10.02
        XCTAssertTrue(window.advanceRaw(pts(2)))
        XCTAssertTrue(window.observeVideo(try video(2)))
        window.closeRawWindow()
        window.observeAudio(audio(3, clock: clock))
        let result = await window.finish()
        XCTAssertEqual(result.outcome, .completed, result.failure ?? "")
        XCTAssertEqual(result.audio.map(\.sourcePTS), [pts(1), pts(2)])
        XCTAssertEqual(result.audio.first?.observedAt, 10)
        XCTAssertEqual(result.startedAt, 10.01)
        XCTAssertEqual(result.followingAudio?.sourcePTS, pts(3))
        XCTAssertEqual(result.maximumPendingCount, 2)
    }

    func testOpeningCoverageFailureRetainsOnlyOriginalScalarPacketEvidence() async throws {
        for preRaw in [false, true] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window)
            clock.now = 10.01
            let rejected = audio(2, clock: clock)
            if preRaw { window.observeAudio(rejected) }
            clock.now = 10.02
            XCTAssertEqual(window.advanceRaw(pts(0)), !preRaw)
            if !preRaw { window.observeAudio(rejected) }
            let result = await window.finish()
            XCTAssertEqual(result.failure, "audioOpeningCoverage")
            let diagnostic = try XCTUnwrap(result.openingAudioFailure)
            XCTAssertEqual(diagnostic.armedAt, 10)
            XCTAssertEqual(diagnostic.rejected.sourcePTS, rejected.sourcePTS)
            XCTAssertEqual(diagnostic.rejected.observedAt, 10.01)
            XCTAssertEqual(diagnostic.rejected.consumedAt, 10.02)
            XCTAssertEqual(diagnostic.rejected.byteCount, 4)
            XCTAssertTrue(result.audio.isEmpty)
            XCTAssertNil(result.followingAudio)
            XCTAssertEqual(result.mux?.audioInputCount, 0)
            clock.now = 11
            window.observeAudio(audio(3, clock: clock))
            let again = await window.finish()
            XCTAssertEqual(again.openingAudioFailure?.rejected.sourcePTS, rejected.sourcePTS)
            XCTAssertEqual(again.openingAudioFailure?.rejected.consumedAt, 10.02)
        }
    }

    func testPreRawAudioUsesTheSameFinitePendingBudget() async {
        let clock = TransportTestClock(), window = owner(clock: clock)
        prepare(window)
        for index in 0..<17 { window.observeAudio(audio(index, clock: clock, bytes: 8184)) }
        let result = await window.finish()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failure, "pendingAudioLimit")
        XCTAssertEqual(result.maximumPendingCount, 16)
        XCTAssertEqual(result.maximumPendingBytes, 16 * 8184)
    }

    func testPreRawBufferStillRejectsWrongGenerationStaleAudioAndCadenceGaps() async {
        for fault in ["generation", "stale", "gap", "opening", "cancel"] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window)
            if fault == "opening" { window.observeAudio(audio(2, clock: clock)) }
            else {
                window.observeAudio(audio(0, clock: clock, generation: fault == "generation" ? 8 : 7,
                                          observed: fault == "stale" ? 9.99 : nil))
                window.observeAudio(audio(fault == "gap" ? 2 : 1, clock: clock))
            }
            if fault == "cancel" { window.cancel() }
            XCTAssertFalse(window.advanceRaw(pts(0)), fault)
            let result = await window.finish()
            XCTAssertEqual(result.outcome, fault == "cancel" ? .cancelled : .failed, fault)
            XCTAssertTrue(result.audio.isEmpty || fault == "gap", fault)
            XCTAssertEqual(result.failure, fault == "cancel" ? nil : fault == "gap" ? "audioCadence"
                           : fault == "opening" ? "audioOpeningCoverage" : "invalidAudio", fault)
        }
    }

    func testPreRangeAudioObservedBeforeRawAnchorIsIgnoredAfterWaitingForWindowLock() async throws {
        let clock = TransportTestClock(), window = owner(clock: clock)
        prepare(window)
        let oldPacket = audio(0, clock: clock)
        clock.now = 10.1
        XCTAssertTrue(window.advanceRaw(pts(1)))
        window.observeAudio(oldPacket)
        window.observeAudio(audio(1, clock: clock))
        XCTAssertTrue(window.observeVideo(try video(1, sync: true)))
        window.closeRawWindow()
        window.observeAudio(audio(2, clock: clock))
        let result = await window.finish()
        XCTAssertEqual(result.outcome, .completed, result.failure ?? "")
        XCTAssertEqual(result.audio.map(\.sourcePTS), [pts(1)])
    }

    func testPreCancelledFirstFinishCannotCommitReadyWindow() async throws {
        for _ in 0..<128 {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            window.observeAudio(audio(0, clock: clock)); XCTAssertTrue(window.observeVideo(try video(0)))
            window.observeAudio(audio(1, clock: clock)); window.closeRawWindow()
            // This task inherits MainActor, so cancellation occurs before its
            // body starts when this test first suspends to await its result.
            let finishing = Task { await window.finish() }
            finishing.cancel()
            let result = await finishing.value
            XCTAssertEqual(result.outcome, .cancelled)
        }
    }

    func testPendingBoundIsSixteenPacketsAndAtMost128KiB() async {
        let clock = TransportTestClock(), window = owner(clock: clock)
        prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
        for index in 1...16 { window.observeAudio(audio(index, clock: clock, bytes: 8184)) }
        window.observeAudio(audio(17, clock: clock, bytes: 8184))
        let result = await window.finish()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failure, "pendingAudioLimit")
        XCTAssertEqual(result.maximumPendingCount, 16)
        XCTAssertEqual(result.maximumPendingBytes, 16 * 8184)
        XCTAssertLessThanOrEqual(result.maximumPendingBytes, 128 * 1024)
    }

    func testSourceGatesAndSingleUseIdentityFailClosed() async {
        for fault in ["unbound", "unarmed", "rebind", "rearm", "invalid", "duplicate", "span", "count"] {
            let window = owner()
            if fault != "unbound" { XCTAssertTrue(window.bind(id: UUID())) }
            if !["unbound", "unarmed"].contains(fault) { XCTAssertTrue(window.arm(publishingGeneration: 7)) }
            if fault == "rebind" { XCTAssertFalse(window.bind(id: UUID())) }
            else if fault == "rearm" { XCTAssertFalse(window.arm(publishingGeneration: 8)) }
            else if fault == "invalid" { XCTAssertFalse(window.advanceRaw(.invalid)) }
            else if fault == "duplicate" { XCTAssertTrue(window.advanceRaw(pts(0))); XCTAssertFalse(window.advanceRaw(pts(0))) }
            else if fault == "span" { XCTAssertTrue(window.advanceRaw(pts(0))); XCTAssertFalse(window.advanceRaw(CMTime(value: 15, timescale: 1))) }
            else if fault == "count" {
                for index in 0..<121 { XCTAssertTrue(window.advanceRaw(CMTime(value: 10000 + Int64(index), timescale: 1000))) }
                XCTAssertFalse(window.advanceRaw(CMTime(value: 10121, timescale: 1000)))
            } else if ["unbound", "unarmed"].contains(fault) { XCTAssertFalse(window.advanceRaw(pts(0))) }
            let result = await window.finish(); XCTAssertEqual(result.outcome, .failed, fault)
        }
    }

    func testAudioIdentityFormatCadenceAndClockFailuresCannotQualify() async {
        for fault in ["generation", "passthrough", "invalid", "format", "gap", "duplicate", "clock", "future", "opening", "size"] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            if !["opening", "size"].contains(fault) { window.observeAudio(audio(0, clock: clock)) }
            window.observeAudio(audio(fault == "gap" || fault == "opening" ? 2 : fault == "duplicate" ? 0 : 1,
                clock: clock, bytes: fault == "size" ? 8185 : 4, generation: fault == "generation" ? 8 : 7,
                wasEncoded: fault != "passthrough", valid: fault != "invalid", rate: fault == "format" ? 44100 : 48000,
                observed: fault == "clock" ? 9 : fault == "future" ? 11 : nil))
            window.closeRawWindow()
            let result = await window.finish(); XCTAssertEqual(result.outcome, .failed, fault)
        }
    }

    func testDelayedWitnessCompletesOneSharedTerminalAndUsesRemainingAllowance() async throws {
        let clock = TransportTestClock(), timer = TransportTestTimer(), window = owner(clock: clock, timer: timer)
        prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
        window.observeAudio(audio(0, clock: clock)); XCTAssertTrue(window.observeVideo(try video(0)))
        window.closeRawWindow()
        let first = Task { await window.finish() }, second = Task { await window.finish() }
        await timer.waitUntilStarted()
        clock.now = 10.5; window.observeAudio(audio(1, clock: clock))
        let a = await first.value, b = await second.value
        XCTAssertEqual(a.outcome, .completed); XCTAssertEqual(a.endedAt, b.endedAt)
        XCTAssertEqual(timer.starts, 1); XCTAssertTrue(timer.joined)
    }

    func testMissingWitnessDeadlineAndLateObservationFailEvenWithDelayedTimer() async throws {
        for lateOffer in [false, true] {
            let clock = TransportTestClock(), timer = TransportTestTimer(), window = owner(clock: clock, timer: timer)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            window.observeAudio(audio(0, clock: clock)); XCTAssertTrue(window.observeVideo(try video(0)))
            window.closeRawWindow(); await timer.waitUntilStarted()
            clock.now = 11.1
            if lateOffer { window.observeAudio(audio(1, clock: clock)) } else { timer.release() }
            let result = await window.finish()
            XCTAssertEqual(result.outcome, .failed); XCTAssertEqual(result.failure, "audioDeadline")
            XCTAssertTrue(timer.joined)
        }
    }

    func testEarlyWitnessSurvivesNativeDrainPastAllowanceButCancellationRevokes() async throws {
        for cancel in [false, true] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            window.observeAudio(audio(0, clock: clock)); XCTAssertTrue(window.observeVideo(try video(0)))
            window.observeAudio(audio(1, clock: clock))
            window.closeRawWindow()
            clock.now = 20
            if cancel { window.cancel() }
            let result = await window.finish()
            XCTAssertEqual(result.outcome, cancel ? .cancelled : .completed)
        }
    }

    func testCancellationWakesAudioWaitAndJoinsTimer() async throws {
        let clock = TransportTestClock(), timer = TransportTestTimer(), window = owner(clock: clock, timer: timer)
        prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
        window.observeAudio(audio(0, clock: clock)); XCTAssertTrue(window.observeVideo(try video(0)))
        window.closeRawWindow()
        let pending = Task { await window.finish() }
        await timer.waitUntilStarted(); window.cancel()
        let result = await pending.value
        XCTAssertEqual(result.outcome, .cancelled); XCTAssertTrue(timer.joined)
    }

    func testMissingNativeOutputAndMuxRejectionCannotComplete() async throws {
        for malformed in [false, true] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            window.observeAudio(audio(0, clock: clock)); window.observeAudio(audio(1, clock: clock))
            if malformed { XCTAssertFalse(window.observeVideo(try video(0, malformed: true))) }
            window.closeRawWindow()
            let result = await window.finish(); XCTAssertEqual(result.outcome, .failed)
        }
    }

    func test44100HzHostClockQuantizationIsAcceptedButOneMicrosecondGapIsRejected() async throws {
        for discontinuity in [false, true] {
            let clock = TransportTestClock(), window = owner(clock: clock)
            prepare(window); XCTAssertTrue(window.advanceRaw(pts(0)))
            window.observeAudio(audio(0, clock: clock, rate: 44100))
            XCTAssertTrue(window.observeVideo(try video(0)))
            window.closeRawWindow()
            window.observeAudio(audio(1, clock: clock, rate: 44100, offset: discontinuity ? 0.000001 : 0))
            let result = await window.finish()
            XCTAssertEqual(result.outcome, discontinuity ? .failed : .completed, result.failure ?? "")
        }
    }

    private func pts(_ index: Int, rate: Double = 48000, offset: Double = 0) -> CMTime {
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10 + Double(index) * 1024 / rate + offset))
        return CMTime(seconds: AVAudioTime.seconds(forHostTime: when.hostTime), preferredTimescale: 1_000_000_000)
    }
    private func audio(_ index: Int, clock: TransportTestClock, bytes: Int = 4, generation: UInt64 = 7,
                       wasEncoded: Bool = true, valid: Bool = true, rate: Double = 48000,
                       observed: Double? = nil, offset: Double = 0) -> PublishingCandidateTransport.AudioSnapshot {
        .init(sourcePTS: pts(index, rate: rate, offset: offset), hostTime: AVAudioTime.hostTime(forSeconds: 10 + Double(index) * 1024 / rate + offset),
              publishingGeneration: generation, wasEncoded: wasEncoded, valid: valid, observedAt: observed ?? clock.now,
              sampleRate: rate, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2, payload: Data(repeating: 42, count: bytes))
    }
    private func video(_ index: Int, malformed: Bool = false, sync: Bool? = nil) throws -> CMSampleBuffer {
        let sps: [UInt8] = [103,77,64,13,218,5,7,236,4,64,0,0,3,0,64,0,0,7,131,197,10,168], pps: [UInt8] = [104,239,60,128]
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: [s.baseAddress!, p.baseAddress!], parameterSetSizes: [s.count,p.count],
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } }
        XCTAssertEqual(status, noErr)
        let bytes: [UInt8] = [0,0,0,2,malformed ? 6 : (sync ?? (index == 0)) ? 0x65 : 0x41,0]
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        bytes.withUnsafeBytes { XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes.count), noErr) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts(index), decodeTimeStamp: .invalid)
        var size = bytes.count, sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(format), sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

private final class TransportTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 10.0
    var now: Double { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
private final class TransportTestTimer: @unchecked Sendable {
    private let lock = NSLock()
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var count = 0, done = false
    init() { (signal, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1)) }
    var starts: Int { lock.withLock { count } }; var joined: Bool { lock.withLock { done } }
    func wait(_ delay: Double) async {
        lock.withLock { count += 1 }
        for await _ in signal {}
        lock.withLock { done = true }
    }
    func release() { continuation.finish() }
    func waitUntilStarted() async {
        let deadline = ContinuousClock.now + .seconds(1)
        while starts == 0 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(starts, 1)
    }
}
