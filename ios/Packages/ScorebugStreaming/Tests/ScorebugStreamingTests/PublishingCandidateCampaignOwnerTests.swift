import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming
@testable import SRTHaishinKit

@MainActor
final class PublishingCandidateCampaignOwnerTests: XCTestCase {
    private func scope() -> VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 7,
              publishingAttemptID: UUID(), appliedProfileRevision: 11)
    }

    func testFreshPairedAttemptsPreservePublicationAndRejectOldIdentity() async throws {
        let factory = CampaignFactory(), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let scope = scope()
        let first = try await owner.begin(scope: scope, profile: .low240, publishingGeneration: 7)
        let old = factory.pair(0)
        XCTAssertEqual(first.id, old.id)
        XCTAssertTrue(owner.offer(try sample(), id: first.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(old.audioCount, 1)
        await owner.retire(id: first.id, reason: .ownerChanged)
        let second = try await owner.begin(scope: scope, profile: .low360, publishingGeneration: 7)
        let fresh = factory.pair(1)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.scope, scope)
        XCTAssertEqual(second.profile, .low360)
        XCTAssertEqual(second.publishingGeneration, first.publishingGeneration)
        XCTAssertFalse(owner.offer(try sample(), id: first.id))
        owner.cancel(id: first.id, reason: .pressure)
        await owner.retire(id: first.id, reason: .pressure)
        let stale = await owner.result(id: first.id)
        XCTAssertNil(stale)
        XCTAssertTrue(owner.offer(try sample(), id: second.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(old.audioCount, 1)
        XCTAssertEqual(fresh.audioCount, 1)
        XCTAssertEqual(fresh.cancelReasons, [])
        XCTAssertEqual(factory.generations, [7, 7])
        await owner.stop()
    }

    func testProductionFactoryStartsAndJoinsTwoFreshPairedAttempts() async throws {
        let owner = PublishingCandidateCampaignOwner(), scope = scope()
        let first = try await owner.begin(scope: scope, profile: .low240, publishingGeneration: 7)
        owner.cancel(id: first.id, reason: .ownerChanged)
        let firstValue = await owner.result(id: first.id)
        let firstResult = try XCTUnwrap(firstValue)
        let firstEncoding = try XCTUnwrap(firstResult.encoding)
        XCTAssertEqual(firstResult.reason, .ownerChanged)
        XCTAssertEqual(firstEncoding.encoding.id, first.id)
        XCTAssertEqual(firstEncoding.encoding.outcome, .cancelled)
        XCTAssertEqual(firstEncoding.transport?.id, first.id)
        XCTAssertEqual(firstEncoding.transport?.publishingGeneration, 7)
        XCTAssertEqual(firstEncoding.transport?.outcome, .cancelled)
        await owner.retire(id: first.id, reason: .ownerChanged)

        let second = try await owner.begin(scope: scope, profile: .low240, publishingGeneration: 7)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.scope, first.scope)
        XCTAssertEqual(second.publishingGeneration, first.publishingGeneration)
        owner.cancel(id: second.id, reason: .publisherStopped)
        let secondValue = await owner.result(id: second.id)
        let secondResult = try XCTUnwrap(secondValue)
        let secondEncoding = try XCTUnwrap(secondResult.encoding)
        XCTAssertEqual(secondResult.reason, .publisherStopped)
        XCTAssertEqual(secondEncoding.encoding.id, second.id)
        XCTAssertEqual(secondEncoding.encoding.outcome, .cancelled)
        XCTAssertEqual(secondEncoding.transport?.id, second.id)
        XCTAssertEqual(secondEncoding.transport?.publishingGeneration, 7)
        XCTAssertEqual(secondEncoding.transport?.outcome, .cancelled)
        // The SDK discovers its session identity from compressed callbacks. A
        // no-frame cancellation may therefore have no session ID to compare.
        if let firstSession = firstEncoding.encoding.encoderSessionID,
           let secondSession = secondEncoding.encoding.encoderSessionID {
            XCTAssertNotEqual(firstSession, secondSession)
        }
        await owner.retire(id: second.id, reason: .publisherStopped)
        await owner.stop()
    }

    func testRepeatedFactoryIdentityCannotReopenRetiredAdmissionAndStillJoinsCleanup() async throws {
        let first = CampaignPair()
        let repeated = CampaignPair(terminalOpen: false, id: first.id)
        let factory = CampaignFactory(pairs: [first, repeated])
        let owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let handle = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        await owner.retire(id: handle.id, reason: .ownerChanged)
        let returned = CampaignFlag()
        let starting = Task {
            defer { returned.set() }
            return try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        }
        await repeated.cancelled.wait()
        await repeated.resultEntered.wait()
        XCTAssertFalse(returned.value)
        XCTAssertFalse(owner.offer(try sample(), id: handle.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(repeated.audioCount, 0)
        await assertBeginError(.busy, owner: owner)
        repeated.terminalGate.open()
        do { _ = try await starting.value; XCTFail("retired identity must not be reused") }
        catch { XCTAssertEqual(error as? PublishingCandidateCampaignOwner.OwnerError, .staleIdentity) }
        XCTAssertEqual(repeated.resultCalls, 1)
        let stale = await owner.result(id: handle.id)
        XCTAssertNil(stale)
        let fresh = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        XCTAssertNotEqual(fresh.id, handle.id)
        XCTAssertTrue(owner.offer(try sample(), id: fresh.id))
        await owner.stop()
    }

    func testOpeningAACDuringArmedStartupReachesRealCandidateTransport() async throws {
        let scope = scope()
        let transport = PublishingCandidateTransport(scope: scope, profile: .low240)
        let encoder = try PublishingCandidateEncoder(scope: scope, profile: .low240, transport: transport)
        let armed = CampaignGate(), startupGate = CampaignGate()
        let measurement = PublishingCandidateMeasurement(scope: scope, profile: .low240,
            operations: .init(id: encoder.id, start: {
                guard transport.arm(publishingGeneration: 7) else { throw CampaignFakeError.startup }
                armed.open()
                await startupGate.wait()
                try await encoder.start()
            }, offer: { encoder.offer($0) }, finish: { await encoder.finish() },
            cancel: { await encoder.cancel() }, rawClosed: { reason in
                if reason == .completed { transport.closeRawWindow() } else { transport.cancel() }
            }, requiresTransport: true))
        let owner = PublishingCandidateCampaignOwner(factory: { _, _, _ in
            .init(id: encoder.id, start: { try await measurement.start() },
                offer: { measurement.offer($0) }, observeAudio: { transport.observeAudio($0) },
                cancel: { measurement.cancel(reason: $0); transport.cancel() },
                result: { await measurement.result() })
        })
        let starting = Task { try await owner.begin(scope: scope, profile: .low240, publishingGeneration: 7) }
        await armed.wait()
        let first = try sample(at: CMTime(value: 10, timescale: 1))
        XCTAssertFalse(owner.offer(first, id: encoder.id), "Raw admission must still wait for encoder startup")
        let opening = try audio(at: 10.014187458)
        owner.observeAudio(opening)
        startupGate.open()
        let handle = try await starting.value
        var nextAudio = 1
        for n in 0...120 {
            let pts = 10 + Double(n) / 30
            XCTAssertTrue(owner.offer(try sample(at: CMTime(value: Int64(300 + n), timescale: 30)), id: handle.id))
            while 10.014187458 + Double(nextAudio) * 1024 / 48000 <= pts {
                owner.observeAudio(try audio(at: 10.014187458 + Double(nextAudio) * 1024 / 48000))
                nextAudio += 1
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        owner.observeAudio(try audio(at: 10.014187458 + Double(nextAudio) * 1024 / 48000))
        let value = await owner.result(id: handle.id)
        let measured = try XCTUnwrap(value)
        XCTAssertEqual(measured.reason, .completed)
        let result = try XCTUnwrap(measured.encoding?.transport)
        XCTAssertEqual(result.outcome, .completed, result.failure ?? "")
        XCTAssertNil(result.openingAudioFailure)
        XCTAssertEqual(result.audio.first?.sourcePTS, opening.sourcePTS)
        XCTAssertEqual(result.audio.first?.observedAt, opening.observedAt)
        XCTAssertGreaterThanOrEqual(opening.observedAt, try XCTUnwrap(measured.startedAt))
        XCTAssertNotNil(PublishingCandidateCost(measured), "Startup AAC must satisfy the unchanged final cost validator")
        XCTAssertGreaterThanOrEqual(result.maximumPendingCount, 1)
        XCTAssertEqual(result.mux?.videoInputCount, 121)
        await owner.stop()
    }

    func testStartupReservesRawAdmissionButRoutesAudioToArmedTransport() async throws {
        let first = CampaignPair(startOpen: false)
        let factory = CampaignFactory(first: first), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let starting = Task { try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7) }
        await first.started.wait()
        XCTAssertFalse(owner.offer(try sample(), id: first.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(first.audioCount, 1)
        await assertBeginError(.busy, owner: owner)
        XCTAssertEqual(factory.count, 1)
        XCTAssertEqual(first.resultCalls, 0, "result must never close an unstarted measurement")
        first.startGate.open()
        let handle = try await starting.value
        XCTAssertTrue(owner.offer(try sample(), id: handle.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(first.audioCount, 2)
        await owner.stop()
    }

    func testNaturalCompletionRetainsSlotAndSharesTerminalResultUntilRetired() async throws {
        let factory = CampaignFactory(), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let handle = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        let pair = factory.pair(0)
        pair.closeRaw()
        let first = await owner.result(id: handle.id)
        let second = await owner.result(id: handle.id)
        XCTAssertEqual(first?.id, handle.id)
        XCTAssertEqual(first?.reason, .completed)
        XCTAssertEqual(second?.endedAt, first?.endedAt)
        XCTAssertEqual(pair.resultCalls, 1)
        await assertBeginError(.busy, owner: owner)
        XCTAssertFalse(owner.offer(try sample(), id: handle.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(pair.audioCount, 0)
        await owner.retire(id: handle.id, reason: .ownerChanged)
        _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        XCTAssertEqual(factory.count, 2)
        await owner.stop()
    }

    func testAudioRemainsRoutedDuringFollowingAudioAllowance() async throws {
        let pair = CampaignPair(terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let handle = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        pair.closeRaw()
        await pair.resultEntered.wait()
        XCTAssertFalse(owner.offer(try sample(), id: handle.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(pair.audioCount, 1)
        pair.terminalGate.open()
        _ = await owner.result(id: handle.id)
        owner.observeAudio(try audio())
        XCTAssertEqual(pair.audioCount, 1)
        await owner.stop()
    }

    func testCancelSynchronouslyRevokesBothRoutesWithoutFreeingSlot() async throws {
        let pair = CampaignPair(terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let handle = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        owner.cancel(id: UUID(), reason: .pressure)
        XCTAssertTrue(owner.offer(try sample(), id: handle.id))
        owner.cancel(id: handle.id, reason: .ownerChanged)
        XCTAssertEqual(pair.cancelReasons, [.ownerChanged])
        XCTAssertFalse(owner.offer(try sample(), id: handle.id))
        owner.observeAudio(try audio())
        XCTAssertEqual(pair.audioCount, 0)
        await assertBeginError(.busy, owner: owner)
        pair.terminalGate.open()
        await owner.retire(id: handle.id, reason: .pressure)
        XCTAssertEqual(pair.resultCalls, 1)
        XCTAssertEqual(pair.cancelReasons, [.ownerChanged])
        await owner.stop()
    }

    func testRetirementJoinsBlockedStartupAndTerminalBeforeFreshAdmission() async throws {
        let pair = CampaignPair(startOpen: false, terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let starting = Task { try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7) }
        await pair.started.wait()
        let retired = CampaignFlag()
        let retiring = Task { await owner.retire(id: pair.id, reason: .ownerChanged); retired.set() }
        await pair.cancelled.wait()
        XCTAssertFalse(retired.value)
        XCTAssertEqual(pair.resultCalls, 0)
        await assertBeginError(.busy, owner: owner)
        pair.startGate.open()
        await pair.resultEntered.wait()
        XCTAssertTrue(pair.startWasCancelled)
        XCTAssertFalse(retired.value)
        await assertBeginError(.busy, owner: owner)
        pair.terminalGate.open()
        await retiring.value
        do { _ = try await starting.value; XCTFail("retired startup must throw") } catch {}
        _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        XCTAssertEqual(pair.resultCalls, 1)
        XCTAssertEqual(factory.count, 2)
        await owner.stop()
    }

    func testCallerCancellationDuringBeginJoinsUncooperativeWork() async throws {
        let pair = CampaignPair(startOpen: false, terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let returned = CampaignFlag()
        let starting = Task {
            defer { returned.set() }
            return try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        }
        await pair.started.wait()
        starting.cancel()
        await pair.cancelled.wait()
        XCTAssertFalse(returned.value)
        XCTAssertFalse(owner.offer(try sample(), id: pair.id))
        pair.startGate.open()
        await pair.resultEntered.wait()
        XCTAssertTrue(pair.startWasCancelled)
        XCTAssertFalse(returned.value)
        await assertBeginError(.busy, owner: owner)
        pair.terminalGate.open()
        do { _ = try await starting.value; XCTFail("cancelled begin must throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(pair.resultCalls, 1)
        _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        await owner.stop()
    }

    func testStartupFailureJoinsTerminalBeforeReleasingSlot() async throws {
        let pair = CampaignPair(terminalOpen: false, failsStart: true)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let returned = CampaignFlag()
        let starting = Task {
            defer { returned.set() }
            return try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        }
        await pair.resultEntered.wait()
        XCTAssertFalse(returned.value)
        XCTAssertFalse(owner.offer(try sample(), id: pair.id))
        await assertBeginError(.busy, owner: owner)
        pair.terminalGate.open()
        do { _ = try await starting.value; XCTFail("startup failure must escape") } catch CampaignFakeError.startup {} catch { XCTFail("\(error)") }
        XCTAssertEqual(pair.resultCalls, 1)
        _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        await owner.stop()
    }

    func testConcurrentRetirementsShareJoinAndLateOldCleanupCannotClearNewOwner() async throws {
        let pair = CampaignPair(terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let old = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7)
        let first = Task { await owner.retire(id: old.id, reason: .ownerChanged) }
        let second = Task { await owner.retire(id: old.id, reason: .ownerChanged) }
        await pair.cancelled.wait()
        await assertBeginError(.busy, owner: owner)
        pair.terminalGate.open()
        await first.value
        let fresh = try await owner.begin(scope: scope(), profile: .low360, publishingGeneration: 7)
        await second.value
        XCTAssertTrue(owner.offer(try sample(), id: fresh.id))
        XCTAssertEqual(pair.resultCalls, 1)
        XCTAssertEqual(pair.cancelReasons, [.ownerChanged])
        await owner.stop()
    }

    func testStopDuringStartupPermanentlyClosesAndSharesRetirementJoin() async throws {
        let pair = CampaignPair(startOpen: false, terminalOpen: false)
        let factory = CampaignFactory(first: pair), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let starting = Task { try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7) }
        await pair.started.wait()
        let stopped = CampaignFlag()
        let stopping = Task { await owner.stop(); stopped.set() }
        await pair.cancelled.wait()
        let duplicate = Task { await owner.stop() }
        let retiring = Task { await owner.retire(id: pair.id, reason: .ownerChanged) }
        XCTAssertFalse(stopped.value)
        await assertBeginError(.closed, owner: owner)
        pair.startGate.open()
        await pair.resultEntered.wait()
        XCTAssertFalse(stopped.value)
        XCTAssertTrue(pair.startWasCancelled)
        pair.terminalGate.open()
        await stopping.value; await duplicate.value; await retiring.value
        do { _ = try await starting.value; XCTFail("stopped startup must throw") } catch {}
        XCTAssertEqual(pair.resultCalls, 1)
        XCTAssertEqual(pair.cancelReasons, [.publisherStopped])
        await assertBeginError(.closed, owner: owner)
        XCTAssertEqual(factory.count, 1)
    }

    func testInvalidGenerationAndEmptyStopNeverAllocatePair() async throws {
        let factory = CampaignFactory(), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        do { _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 0); XCTFail("zero generation") }
        catch { XCTAssertEqual(error as? PublishingCandidateCampaignOwner.OwnerError, .invalidGeneration) }
        await owner.stop()
        await assertBeginError(.closed, owner: owner)
        XCTAssertEqual(factory.count, 0)
        let unknown = await owner.result(id: UUID())
        XCTAssertNil(unknown)
    }

    func testAlreadyCancelledBeginDoesNotAllocatePair() async throws {
        let factory = CampaignFactory(), owner = PublishingCandidateCampaignOwner(factory: factory.make)
        let starting = Task { try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7) }
        starting.cancel()
        do { _ = try await starting.value; XCTFail("cancelled caller") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(factory.count, 0)
        await owner.stop()
    }

    private func assertBeginError(_ expected: PublishingCandidateCampaignOwner.OwnerError,
                                  owner: PublishingCandidateCampaignOwner,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await owner.begin(scope: scope(), profile: .low240, publishingGeneration: 7); XCTFail("begin must fail", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingCandidateCampaignOwner.OwnerError, expected, file: file, line: line) }
    }

    private func sample(at pts: CMTime = .zero) throws -> CapturedMediaSample {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &buffer), noErr)
        return try .init(sampleBuffer: XCTUnwrap(buffer), kind: .video)
    }

    private func audio(at seconds: Double? = nil) throws -> SRTPublisher.CompressedAudioFrame {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 4)
        buffer.byteLength = 4; buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = .init(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: 4)
        memset(buffer.data, 0, 4)
        return .init(buffer: buffer, when: AVAudioTime(hostTime: seconds.map(AVAudioTime.hostTime(forSeconds:)) ?? 1_000_000), generation: 7, wasEncoded: true)
    }
}

/// Cancellation intentionally does not open these gates: native work may remain
/// in flight after revocation, and the public owner must still join it.
private final class CampaignGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = false) { opened = open }
    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}
private final class CampaignFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
private enum CampaignFakeError: Error { case startup }
private final class CampaignPair: @unchecked Sendable {
    let id: UUID
    let startGate: CampaignGate, terminalGate: CampaignGate
    let started = CampaignGate(), resultEntered = CampaignGate(), cancelled = CampaignGate()
    private let closed = CampaignGate(), lock = NSLock()
    private let failsStart: Bool
    private var rawClosed = false, finished = false, reasons: [PublishingCandidateMeasurement.Reason] = []
    private var audioCalls = 0, results = 0, startCancelled = false
    init(startOpen: Bool = true, terminalOpen: Bool = true, failsStart: Bool = false, id: UUID = UUID()) {
        self.id = id
        startGate = .init(open: startOpen); terminalGate = .init(open: terminalOpen); self.failsStart = failsStart
    }
    var audioCount: Int { lock.withLock { audioCalls } }
    var resultCalls: Int { lock.withLock { results } }
    var cancelReasons: [PublishingCandidateMeasurement.Reason] { lock.withLock { reasons } }
    var startWasCancelled: Bool { lock.withLock { startCancelled } }
    func closeRaw() { lock.withLock { rawClosed = true }; closed.open() }
    func operations(scope: VideoFrameObservationScope, profile: PublishingVideoProfile) -> PublishingCandidateCampaignOwner.Operations {
        .init(id: id, start: { [self] in
            started.open(); await startGate.wait()
            lock.withLock { startCancelled = Task.isCancelled }
            if failsStart { throw CampaignFakeError.startup }
        }, offer: { [self] _ in lock.withLock { !rawClosed && reasons.isEmpty && !finished } },
        observeAudio: { [self] _ in lock.withLock { audioCalls += 1 } },
        cancel: { [self] reason in
            lock.withLock { reasons.append(reason); rawClosed = true }
            cancelled.open(); closed.open()
        }, result: { [self] in
            lock.withLock { results += 1 }; resultEntered.open()
            await closed.wait(); await terminalGate.wait()
            return lock.withLock {
                finished = true
                return .init(id: id, scope: scope, profile: profile, reason: reasons.first ?? .completed,
                    startedAt: 10, endedAt: 14, acceptedInputCount: 0, firstInputPTS: nil, lastInputPTS: nil, encoding: nil)
            }
        })
    }
}
private final class CampaignFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let prepared: [CampaignPair]
    private var pairs: [CampaignPair] = [], values: [UInt64] = []
    init(first: CampaignPair? = nil) { prepared = first.map { [$0] } ?? [] }
    init(pairs: [CampaignPair]) { prepared = pairs }
    var count: Int { lock.withLock { pairs.count } }
    var generations: [UInt64] { lock.withLock { values } }
    func pair(_ index: Int) -> CampaignPair { lock.withLock { pairs[index] } }
    func make(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
              publishingGeneration: UInt64) throws -> PublishingCandidateCampaignOwner.Operations {
        lock.withLock {
            let pair = pairs.count < prepared.count ? prepared[pairs.count] : CampaignPair()
            pairs.append(pair); values.append(publishingGeneration)
            return pair.operations(scope: scope, profile: profile)
        }
    }
}
