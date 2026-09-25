import AVFoundation
import CoreMedia
import Foundation
import ScorebugMedia
import SRTHaishinKit

/// A finite source-aligned window of live AAC and off-network candidate H.264.
public final class PublishingCandidateTransport: @unchecked Sendable {
    public enum Outcome: String, Sendable { case completed, failed, cancelled }
    public struct AudioReceipt: Sendable {
        public let sourcePTS: CMTime
        public let publishingGeneration: UInt64
        public let wasEncoded: Bool
        public let valid: Bool
        public let observedAt: Double
        public let consumedAt: Double
        public let byteCount: Int
        public let sampleRate: Double
        public let channelCount: UInt32
        public let framesPerPacket: UInt32
        public let audioObjectType: UInt32
    }
    /// Constant-size diagnostics for the first rejected opening packet. No payload retained.
    public struct OpeningAudioFailure: Sendable {
        public let armedAt: Double
        public let rejected: AudioReceipt
    }
    public struct Result: Sendable {
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        public let id: UUID?
        public let outcome: Outcome
        public let failure: String?
        public let publishingGeneration: UInt64?
        public let startedAt: Double?
        public let closedAt: Double?
        public let endedAt: Double
        public let rawInputCount: Int
        public let firstRawPTS: CMTime?
        public let lastRawPTS: CMTime?
        public let audio: [AudioReceipt]
        public let followingAudio: AudioReceipt?
        public let openingAudioFailure: OpeningAudioFailure?
        public let maximumPendingCount: Int
        public let maximumPendingBytes: Int
        public let mux: CandidateTransportMeasurement.Result?
    }
    struct AudioSnapshot: Sendable {
        let sourcePTS: CMTime
        let hostTime: UInt64
        let publishingGeneration: UInt64
        let wasEncoded: Bool
        let valid: Bool
        let observedAt: Double
        let sampleRate: Double
        let channelCount: UInt32
        let framesPerPacket: UInt32
        let audioObjectType: UInt32
        let payload: Data
    }
    public let scope: VideoFrameObservationScope
    public let profile: PublishingVideoProfile
    private let state: CandidateTransportState
    private let terminal: Task<Result, Never>
    public convenience init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile) {
        self.init(scope: scope, profile: profile, now: { ProcessInfo.processInfo.systemUptime },
                  deadlineWait: { try? await Task.sleep(for: .seconds($0)) })
    }
    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
         now: @escaping @Sendable () -> Double,
         deadlineWait: @escaping @Sendable (Double) async -> Void) {
        self.scope = scope; self.profile = profile
        let state = CandidateTransportState(scope: scope, profile: profile, now: now, deadlineWait: deadlineWait)
        self.state = state
        terminal = Task {
            for await _ in state.terminalSignal {}
            await state.joinDeadline()
            return state.complete()
        }
    }
    deinit { state.cancel() }
    @discardableResult public func bind(id: UUID) -> Bool { state.bind(id) }
    @discardableResult public func arm(publishingGeneration: UInt64) -> Bool { state.arm(publishingGeneration) }
    /// Releases the window lock before the caller enters the candidate encoder.
    @discardableResult public func advanceRaw(_ pts: CMTime) -> Bool { state.advanceRaw(pts) }
    public func observeAudio(_ frame: SRTPublisher.CompressedAudioFrame) {
        state.observeAudio(.init(sourcePTS: frame.sourcePTS, hostTime: frame.hostTime,
            publishingGeneration: frame.publishingGeneration, wasEncoded: frame.wasEncoded,
            valid: frame.valid, observedAt: frame.observedAt, sampleRate: frame.sampleRate,
            channelCount: frame.channelCount, framesPerPacket: frame.framesPerPacket,
            audioObjectType: frame.audioObjectType, payload: frame.payload))
    }
    func observeAudio(_ frame: AudioSnapshot) { state.observeAudio(frame) }
    @discardableResult public func observeVideo(_ sample: CMSampleBuffer) -> Bool { state.observeVideo(sample) }
    public func closeRawWindow() { state.closeRawWindow() }
    public func cancel() { state.cancel() }
    /// Call only after native candidate completion has joined. All callers share
    /// one terminal operation and join the remaining audio allowance, if needed.
    public func finish() async -> Result {
        return await withTaskCancellationHandler {
            state.requestFinish()
            return await terminal.value
        } onCancel: { state.cancel() }
    }
}

/// Lock order: measurement -> candidate -> this state -> mux. This owner never
/// enters either upstream owner, and never schedules work per packet or frame.
private final class CandidateTransportState: @unchecked Sendable {
    typealias Owner = PublishingCandidateTransport
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private let profile: PublishingVideoProfile
    private let now: @Sendable () -> Double
    private let deadlineWait: @Sendable (Double) async -> Void
    private let mux = CandidateTransportMeasurement()
    let terminalSignal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var id: UUID?, generation: UInt64?
    private var firstPTS: CMTime?, lastPTS: CMTime?
    private var armedAt: Double?, startedAt: Double?, closedAt: Double?
    private var count = 0, pendingBytes = 0, maximumPendingCount = 0, maximumPendingBytes = 0
    private var pending: [Owner.AudioSnapshot] = []
    private var audio: [Owner.AudioReceipt] = []
    private var following: Owner.AudioReceipt?
    private var openingAudioFailure: Owner.OpeningAudioFailure?
    private var previousAudio: Owner.AudioSnapshot?
    private var deadline: Task<Void, Never>?
    private var finishRequested = false, cancelled = false
    private var failure: String?
    private var result: Owner.Result?

    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
         now: @escaping @Sendable () -> Double, deadlineWait: @escaping @Sendable (Double) async -> Void) {
        self.scope = scope; self.profile = profile; self.now = now; self.deadlineWait = deadlineWait
        (terminalSignal, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    }
    private var active: Bool { result == nil && failure == nil && !cancelled }
    private func fail(_ reason: String) {
        guard result == nil else { return }
        failure = failure ?? reason
        pending.removeAll(); pendingBytes = 0; previousAudio = nil
        continuation.finish()
    }
    func bind(_ value: UUID) -> Bool {
        lock.withLock {
            guard active else { return false }
            guard id == nil else { fail("candidateIdentity"); return false }
            id = value; return true
        }
    }
    func arm(_ value: UInt64) -> Bool {
        lock.withLock {
            guard active else { return false }
            guard id != nil, generation == nil, value > 0 else { fail("publishingGeneration"); return false }
            guard let at = clock() else { return false }
            armedAt = at; generation = value; return true
        }
    }
    private func valid(_ pts: CMTime) -> Bool {
        pts.isNumeric && pts.timescale > 0 && pts.epoch == 0 && pts.value >= 0
    }
    private func clock() -> Double? {
        let at = now()
        let minimum = max(startedAt ?? armedAt ?? 0, max(closedAt ?? 0, following?.consumedAt ?? audio.last?.consumedAt ?? 0))
        guard at.isFinite, at >= minimum else { fail("invalidClock"); return nil }
        return at
    }
    private func withinAudioDeadline(_ at: Double) -> Bool {
        if following == nil, let closedAt, at - closedAt > 1 { fail("audioDeadline"); return false }
        return true
    }
    func advanceRaw(_ pts: CMTime) -> Bool {
        lock.withLock {
            guard active, closedAt == nil else { return false }
            guard id != nil, generation != nil else { fail("notArmed"); return false }
            guard valid(pts), count < 121, lastPTS.map({ CMTimeCompare($0, pts) < 0 }) ?? true,
                  firstPTS.map({ CMTimeCompare(CMTimeSubtract(pts, $0), CMTime(value: 17, timescale: 4)) <= 0 }) ?? true else {
                fail("rawInput"); return false
            }
            guard let at = clock() else { return false }
            let opening = firstPTS == nil
            startedAt = startedAt ?? at; firstPTS = firstPTS ?? pts; lastPTS = pts; count += 1
            if opening {
                // AAC and raw video have independent callback ordering. Retain
                // one bounded pre-opening queue, then select by source PTS.
                let queued = pending
                pending.removeAll(); pendingBytes = 0
                for frame in queued {
                    acceptAudio(frame)
                    guard active else { return false }
                }
            }
            while let frame = pending.first, CMTimeCompare(frame.sourcePTS, pts) <= 0 {
                pending.removeFirst(); pendingBytes -= frame.payload.count
                guard appendAudio(frame) else { return false }
            }
            return true
        }
    }
    func observeAudio(_ frame: Owner.AudioSnapshot) {
        lock.withLock {
            guard active, let armedAt, following == nil else { return }
            guard let at = clock(), withinAudioDeadline(at) else { return }
            let hostPTS = CMTime(seconds: AVAudioTime.seconds(forHostTime: frame.hostTime), preferredTimescale: 1_000_000_000)
            guard frame.valid, frame.wasEncoded, frame.publishingGeneration == generation,
                  valid(frame.sourcePTS), CMTimeCompare(frame.sourcePTS, hostPTS) == 0,
                  frame.observedAt.isFinite, frame.observedAt >= 0, frame.observedAt <= at,
                  frame.payload.count > 0, frame.payload.count <= 8184,
                  [96_000.0, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350].contains(frame.sampleRate),
                  (1...6).contains(frame.channelCount) || frame.channelCount == 8,
                  frame.framesPerPacket == 1024, frame.audioObjectType == 2 else { fail("invalidAudio"); return }
            if let firstPTS, CMTimeCompare(frame.sourcePTS, firstPTS) < 0 { return }
            guard frame.observedAt >= armedAt else { fail("invalidAudio"); return }
            if firstPTS == nil { enqueue(frame) }
            else { acceptAudio(frame) }
        }
    }
    private func enqueue(_ frame: Owner.AudioSnapshot) {
        guard pending.count < 16, frame.payload.count <= 128 * 1024 - pendingBytes else { fail("pendingAudioLimit"); return }
        pending.append(frame); pendingBytes += frame.payload.count
        maximumPendingCount = max(maximumPendingCount, pending.count)
        maximumPendingBytes = max(maximumPendingBytes, pendingBytes)
    }
    private func acceptAudio(_ frame: Owner.AudioSnapshot) {
        guard let firstPTS, let lastPTS else { return }
        if CMTimeCompare(frame.sourcePTS, firstPTS) < 0 { return }
        if let previousAudio {
            let delta = CMTimeSubtract(frame.sourcePTS, previousAudio.sourcePTS).seconds
            // Host ticks are 41.67 ns on measured Apple Silicon; allow two
            // ticks plus nanosecond projection rounding, never a packet gap.
            guard frame.sampleRate == previousAudio.sampleRate, frame.channelCount == previousAudio.channelCount,
                  frame.observedAt >= previousAudio.observedAt,
                  delta > 0, abs(delta - 1024 / frame.sampleRate) <= 0.000000100 else { fail("audioCadence"); return }
        } else {
            guard CMTimeSubtract(frame.sourcePTS, firstPTS).seconds <= 1024 / frame.sampleRate + 0.000000100 else {
                guard let armedAt, let at = clock() else { return }
                openingAudioFailure = .init(armedAt: armedAt, rejected: receipt(frame, consumedAt: at))
                fail("audioOpeningCoverage"); return
            }
        }
        // Keep only the scalar cadence anchor, never a second retained payload.
        previousAudio = .init(sourcePTS: frame.sourcePTS, hostTime: frame.hostTime,
            publishingGeneration: frame.publishingGeneration, wasEncoded: frame.wasEncoded, valid: frame.valid,
            observedAt: frame.observedAt, sampleRate: frame.sampleRate, channelCount: frame.channelCount,
            framesPerPacket: frame.framesPerPacket, audioObjectType: frame.audioObjectType, payload: Data())
        if CMTimeCompare(frame.sourcePTS, lastPTS) <= 0 { _ = appendAudio(frame) }
        else if closedAt != nil { selectFollowing(frame) }
        else { enqueue(frame) }
    }
    private func receipt(_ frame: Owner.AudioSnapshot, consumedAt: Double) -> Owner.AudioReceipt {
        .init(sourcePTS: frame.sourcePTS, publishingGeneration: frame.publishingGeneration,
              wasEncoded: frame.wasEncoded, valid: frame.valid, observedAt: frame.observedAt, consumedAt: consumedAt,
              byteCount: frame.payload.count, sampleRate: frame.sampleRate, channelCount: frame.channelCount,
              framesPerPacket: frame.framesPerPacket, audioObjectType: frame.audioObjectType)
    }
    private func appendAudio(_ frame: Owner.AudioSnapshot) -> Bool {
        guard audio.count < 512 else { fail("audioInputLimit"); return false }
        var asbd = AudioStreamBasicDescription(mSampleRate: frame.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: frame.audioObjectType, mBytesPerPacket: 0, mFramesPerPacket: frame.framesPerPacket,
            mBytesPerFrame: 0, mChannelsPerFrame: frame.channelCount, mBitsPerChannel: 0, mReserved: 0)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | frame.channelCount)
        guard let format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout) else { fail("audioFormat"); return false }
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: frame.payload.count)
        buffer.byteLength = UInt32(frame.payload.count); buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = .init(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: buffer.byteLength)
        frame.payload.withUnsafeBytes { buffer.data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        guard mux.appendAudio(buffer, when: AVAudioTime(hostTime: frame.hostTime)) else { fail("muxAudio"); return false }
        guard let at = clock(), withinAudioDeadline(at) else { return false }
        guard at >= frame.observedAt else { fail("invalidClock"); return false }
        audio.append(receipt(frame, consumedAt: at)); return true
    }
    private func selectFollowing(_ frame: Owner.AudioSnapshot) {
        guard !audio.isEmpty else { fail("missingSelectedAudio"); return }
        guard let at = clock(), withinAudioDeadline(at) else { return }
        guard at >= frame.observedAt else { fail("invalidClock"); return }
        following = receipt(frame, consumedAt: at)
        pending.removeAll(); pendingBytes = 0; previousAudio = nil
        deadline?.cancel()
        if finishRequested { continuation.finish() }
    }
    func observeVideo(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard active, !finishRequested, let firstPTS, let lastPTS else { return false }
            guard let at = clock(), withinAudioDeadline(at) else { return false }
            guard valid(sample.presentationTimeStamp), CMTimeCompare(sample.presentationTimeStamp, firstPTS) >= 0,
                  CMTimeCompare(sample.presentationTimeStamp, lastPTS) <= 0,
                  mux.appendVideo(sample) else { fail("muxVideo"); return false }
            return true
        }
    }
    func closeRawWindow() { lock.withLock { closeRaw() } }
    private func closeRaw() {
        guard active, closedAt == nil else { return }
        guard count > 0, let at = clock() else { fail("emptyRawWindow"); return }
        closedAt = at
        if let next = pending.first { selectFollowing(next) }
        guard active, following == nil else { return }
        deadline = Task { [self] in
            let remaining = lock.withLock { () -> Double in
                guard let at = clock(), let closedAt else { return 0 }
                return max(0, 1 - (at - closedAt))
            }
            await deadlineWait(remaining)
            if !Task.isCancelled {
                lock.withLock { if active, following == nil { fail("audioDeadline") } }
            }
        }
    }
    func requestFinish() {
        lock.withLock {
            guard result == nil else { return }
            closeRaw(); finishRequested = true
            if let at = clock() { _ = withinAudioDeadline(at) }
            if failure != nil || cancelled || following != nil { continuation.finish() }
        }
    }
    func cancel() {
        lock.withLock {
            guard result == nil else { return }
            cancelled = true; pending.removeAll(); pendingBytes = 0; previousAudio = nil
            continuation.finish()
        }
    }
    func joinDeadline() async {
        let timer = lock.withLock { deadline }
        timer?.cancel(); await timer?.value
    }
    func complete() -> Owner.Result {
        lock.withLock {
            if let result { return result }
            if !cancelled, failure == nil {
                if !finishRequested { failure = "nativeJoinNotRequested" }
                if following == nil || audio.isEmpty || count == 0 { failure = failure ?? "incompleteAudio" }
            }
            let measured = cancelled || failure != nil ? mux.cancel() : mux.finish()
            if !cancelled, failure == nil {
                if measured.outcome != .completed || measured.videoInputCount != count || measured.audioInputCount != audio.count
                    || measured.firstVideoPTS.map({ CMTimeCompare($0, firstPTS ?? .invalid) == 0 }) != true
                    || measured.lastVideoPTS.map({ CMTimeCompare($0, lastPTS ?? .invalid) == 0 }) != true {
                    failure = "incompleteMux"
                }
            }
            let at = clock() ?? max(startedAt ?? 0, closedAt ?? 0)
            let completed = Owner.Result(scope: scope, profile: profile, id: id,
                outcome: cancelled ? .cancelled : failure == nil ? .completed : .failed, failure: failure,
                publishingGeneration: generation, startedAt: startedAt, closedAt: closedAt, endedAt: at,
                rawInputCount: count, firstRawPTS: firstPTS, lastRawPTS: lastPTS, audio: audio,
                followingAudio: following, openingAudioFailure: openingAudioFailure, maximumPendingCount: maximumPendingCount,
                maximumPendingBytes: maximumPendingBytes, mux: measured)
            result = completed; deadline = nil; pending.removeAll(); previousAudio = nil
            return completed
        }
    }
}
