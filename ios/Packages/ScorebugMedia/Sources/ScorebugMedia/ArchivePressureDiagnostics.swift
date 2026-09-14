#if DEBUG
import CoreMedia
import Foundation

/// Bounded value-only observations. The injected clock must be non-reentrant.
/// Lock order is media -> diagnostics; this owner never calls back into media.
public final class ArchivePressureDiagnostics: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable { case video, audio }
    public enum SegmentKind: String, Codable, Sendable { case initialization, media }
    public enum AppendResult: String, Codable, Sendable { case accepted, notReady, failure }
    public enum PersistenceResult: String, Codable, Sendable { case success, failure }
    public enum Phase: String, Codable, Sendable { case dequeued, append, retryWait, returned, completed }
    public enum FailureCode: String, Codable, Sendable {
        case invalidState, invalidTimestamp, invalidRetryPolicy, overflow, backpressureTimedOut, sinkFailed, cancelled, captureFailed
        init(_ error: RecordingSessionError) {
            switch error {
            case .invalidState: self = .invalidState
            case .invalidTimestamp: self = .invalidTimestamp
            case .invalidRetryPolicy: self = .invalidRetryPolicy
            case .overflow: self = .overflow
            case .backpressureTimedOut: self = .backpressureTimedOut
            case .sinkFailed: self = .sinkFailed
            case .cancelled: self = .cancelled
            case .captureFailed: self = .captureFailed
            }
        }
    }
    public struct PTS: Codable, Equatable, Sendable {
        public let value: String
        public let timescale: Int32
        public let epoch: String
        public let flags: UInt32
        init(_ time: CMTime) {
            value = String(time.value); timescale = time.timescale
            epoch = String(time.epoch); flags = time.flags.rawValue
        }
    }
    public struct Sample: Codable, Equatable, Sendable {
        public let kind: Kind
        public let pts: PTS
        public let bytes: String
        public init(kind: Kind, pts: CMTime, bytes: Int) {
            self.kind = kind; self.pts = PTS(pts); self.bytes = String(bytes)
        }
        init(_ sample: CapturedMediaSample) {
            self.init(kind: sample.kind == .video ? .video : .audio,
                      pts: sample.sampleBuffer.presentationTimeStamp, bytes: sample.retainedByteCount)
        }
    }
    public struct QueueLimits: Codable, Equatable, Sendable {
        public let maxItems: String
        public let maxBytes: String
    }
    public struct Queue: Codable, Equatable, Sendable {
        public let currentItems, currentBytes, peakItems, peakBytes: String
        public let acceptedCount, rejectedCount, droppedCount: String
        public let hasPendingConsumer: Bool
        init(_ stats: BoundedMailbox<CapturedMediaSample>.Statistics) {
            currentItems = String(stats.currentItems); currentBytes = String(stats.currentBytes)
            peakItems = String(stats.peakItems); peakBytes = String(stats.peakBytes)
            acceptedCount = String(stats.acceptedCount); rejectedCount = String(stats.rejectedCount)
            droppedCount = String(stats.droppedCount); hasPendingConsumer = stats.hasPendingConsumer
        }
    }
    public struct Coverage: Codable, Equatable, Sendable {
        public internal(set) var producer = false
        public internal(set) var session = false
        public internal(set) var persistence = false
        public internal(set) var persistenceComplete = true
    }
    public struct Validity: Codable, Equatable, Sendable {
        public internal(set) var timingValid = true
        public internal(set) var counterOverflow = false
        public internal(set) var invalidToken = false
        public internal(set) var invalidSequence = false
    }
    public struct Producer: Codable, Equatable, Sendable {
        public let frameIndex: String
        public let deadline: Double?
        public let generationStart: Double?
        public internal(set) var generationEnd: Double?
        public internal(set) var callbackStart: Double?
        public internal(set) var callbackEnd: Double?
    }
    public struct Consumer: Codable, Equatable, Sendable {
        public let sample: Sample
        public let started: Double?
        public internal(set) var ended: Double?
        public internal(set) var phase: Phase = .dequeued
        public internal(set) var phaseStarted: Double?
        public internal(set) var attemptCount = "0"
        public internal(set) var falseCount = "0"
        public internal(set) var appendElapsed: Double? = 0
        public internal(set) var appendMaximum: Double? = 0
        public internal(set) var retryWaitElapsed: Double? = 0
        public internal(set) var readinessSince: Double?
        public internal(set) var readinessElapsed: Double?
        public internal(set) var lastAppendResult: AppendResult?
    }
    public struct PersistenceToken: Hashable, Sendable { fileprivate let value: UInt64 }
    public struct Persistence: Codable, Equatable, Sendable {
        public let token: String
        public let kind: SegmentKind
        public let bytes: String
        public let started: Double?
        public internal(set) var ended: Double?
        public internal(set) var elapsed: Double?
        public internal(set) var result: PersistenceResult?
    }
    public struct History<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        public let completed: [T]
        public let oldestRetainedTime: Double?
        public let omittedCount: String
    }
    public struct Observations: Codable, Equatable, Sendable {
        public let producers: History<Producer>
        public let consumers: History<Consumer>
        public let persistences: History<Persistence>
        public let activeProducer: Producer?
        public let activeConsumer: Consumer?
        public let activePersistences: [Persistence]
        public let omittedActivePersistences: String
        public let audioAccepted, audioRejected, videoAccepted, videoRejected: String
    }
    public struct Failure: Codable, Equatable, Sendable {
        public let detectedAt: Double?
        public let reason: FailureCode
        public let rejection: String?
        public let sample: Sample?
        public let queue: Queue?
        public let writtenSamples: String
        public let coverage: Coverage
        public let validity: Validity
        public let observations: Observations
    }
    public struct Terminal: Codable, Equatable, Sendable {
        public let state: String
        public let failure: FailureCode?
        public let writtenSamples: String
        public let queue: Queue
    }
    public struct Snapshot: Codable, Equatable, Sendable {
        public let recordingID: String
        public let queueLimits: QueueLimits?
        public let profile: ArchiveProfile?
        public let coverage: Coverage
        public let validity: Validity
        public let observedAt: Double?
        public let observations: Observations
        public let firstFailure: Failure?
        public let terminal: Terminal?
        public let closed: Bool
    }

    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var anchor: ContinuousClock.Instant!
    private var previous: ContinuousClock.Instant!
    private let recordingID: String
    private var queueLimits: QueueLimits?
    private var profile: ArchiveProfile?
    private var coverage = Coverage()
    private var validity = Validity()
    private var producer: Producer?
    private var consumer: Consumer?
    private var producers: [Producer] = []
    private var consumers: [Consumer] = []
    private var persistences: [Persistence] = []
    private var activePersistences: [Persistence] = []
    private var producerOmitted: UInt64 = 0
    private var consumerOmitted: UInt64 = 0
    private var persistenceOmitted: UInt64 = 0
    private var activeOmitted: UInt64 = 0
    private var tokenSequence: UInt64 = 0
    private var audioAccepted: UInt64 = 0
    private var audioRejected: UInt64 = 0
    private var videoAccepted: UInt64 = 0
    private var videoRejected: UInt64 = 0
    private var attempts: UInt64 = 0
    private var falseReturns: UInt64 = 0
    private var firstFailure: Failure?
    private var closedSnapshot: Snapshot?

    public init(recordingID: String, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.recordingID = recordingID; self.now = now
        lock.withLock { anchor = now(); previous = anchor }
    }

    /// Each participating component can claim its coverage only once, before use.
    @discardableResult public func attachProducer() -> Bool {
        lock.withLock {
            guard closedSnapshot == nil, !coverage.producer else { return false }
            coverage.producer = true; return true
        }
    }
    func attachSession(maxItems: Int, maxBytes: Int) -> Bool {
        lock.withLock {
            guard closedSnapshot == nil, !coverage.session else { return false }
            coverage.session = true
            queueLimits = QueueLimits(maxItems: String(maxItems), maxBytes: String(maxBytes))
            return true
        }
    }
    func attachPersistence(profile: ArchiveProfile) -> Bool {
        lock.withLock {
            guard closedSnapshot == nil, !coverage.persistence else { return false }
            coverage.persistence = true; self.profile = profile; return true
        }
    }
    public func beginFrame(index: Int64, deadline: ContinuousClock.Instant) {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard producer == nil else { validity.invalidSequence = true; return }
            producer = Producer(frameIndex: String(index), deadline: relative(deadline), generationStart: time)
        }
    }
    public func generationFinished() {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard producer != nil, producer?.generationEnd == nil, producer?.callbackStart == nil else {
                validity.invalidSequence = true; return
            }
            producer?.generationEnd = time
        }
    }
    public func callbacksStarted() {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard producer != nil, producer?.callbackStart == nil else { validity.invalidSequence = true; return }
            producer?.callbackStart = time
        }
    }
    public func callbacksFinished() {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard var completed = producer else { validity.invalidSequence = true; return }
            completed.callbackEnd = time
            if producers.count == 32 { producers.removeFirst(); increment(&producerOmitted) }
            producers.append(completed); producer = nil
        }
    }
    func observeOffer(kind: Kind, accepted: Bool) {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            _ = stamp()
            switch (kind, accepted) {
            case (.audio, true): increment(&audioAccepted)
            case (.audio, false): increment(&audioRejected)
            case (.video, true): increment(&videoAccepted)
            case (.video, false): increment(&videoRejected)
            }
        }
    }
    func consumerStarted(_ sample: Sample) {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard consumer == nil else { validity.invalidSequence = true; return }
            consumer = Consumer(sample: sample, started: time, phaseStarted: time)
            attempts = 0; falseReturns = 0
        }
    }
    func appendStarted() {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard var current = consumer, current.phase == .dequeued || current.phase == .retryWait else {
                validity.invalidSequence = true; return
            }
            if current.phase == .retryWait {
                current.retryWaitElapsed = sum(current.retryWaitElapsed, elapsed(current.phaseStarted, time))
            }
            increment(&attempts); current.attemptCount = String(attempts)
            current.phase = .append; current.phaseStarted = time; consumer = current
        }
    }
    func appendFinished(_ result: AppendResult) {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard var current = consumer, current.phase == .append else { validity.invalidSequence = true; return }
            let duration = elapsed(current.phaseStarted, time)
            current.appendElapsed = sum(current.appendElapsed, duration)
            current.appendMaximum = maximum(current.appendMaximum, duration)
            current.lastAppendResult = result
            if result == .notReady {
                increment(&falseReturns); current.falseCount = String(falseReturns)
                if falseReturns == 1 { current.readinessSince = time }
                current.phase = .retryWait
            } else { current.phase = .returned }
            current.phaseStarted = time; consumer = current
        }
    }
    // Caller holds RecordingCore's lock while incrementing its written count.
    func consumerWritten() {
        lock.withLock {
            guard closedSnapshot == nil else { return }
            let time = stamp()
            guard var completed = consumer, completed.lastAppendResult == .accepted else {
                validity.invalidSequence = true; return
            }
            completed.ended = time; completed.phase = .completed; completed.phaseStarted = time
            completed.readinessElapsed = elapsed(completed.readinessSince, time)
            if consumers.count == 64 { consumers.removeFirst(); increment(&consumerOmitted) }
            consumers.append(completed); consumer = nil
        }
    }
    func persistenceStarted(kind: SegmentKind, bytes: Int) -> PersistenceToken? {
        lock.withLock {
            guard closedSnapshot == nil else { return nil }
            let time = stamp()
            guard activePersistences.count < 4, tokenSequence < .max else {
                increment(&activeOmitted); coverage.persistenceComplete = false
                if tokenSequence == .max { validity.counterOverflow = true }
                return nil
            }
            increment(&tokenSequence)
            activePersistences.append(Persistence(token: String(tokenSequence), kind: kind, bytes: String(bytes), started: time))
            return PersistenceToken(value: tokenSequence)
        }
    }
    func persistenceFinished(_ token: PersistenceToken?, result: PersistenceResult) {
        lock.withLock {
            guard closedSnapshot == nil, let token else { return }
            let time = stamp()
            guard let index = activePersistences.firstIndex(where: { $0.token == String(token.value) }) else {
                validity.invalidToken = true; return
            }
            var completed = activePersistences.remove(at: index)
            completed.ended = time; completed.elapsed = elapsed(completed.started, time); completed.result = result
            if persistences.count == 32 { persistences.removeFirst(); increment(&persistenceOmitted) }
            persistences.append(completed)
        }
    }
    func freezeFailure(_ error: RecordingSessionError,
                       rejection: BoundedMailbox<CapturedMediaSample>.RejectionReason?, sample: Sample?,
                       queue: BoundedMailbox<CapturedMediaSample>.Statistics?, writtenSamples: Int) {
        lock.withLock {
            guard closedSnapshot == nil, firstFailure == nil else { return }
            let time = stamp()
            let observations = observations(at: time)
            firstFailure = Failure(detectedAt: time, reason: FailureCode(error),
                rejection: rejection.map { String(describing: $0) }, sample: sample, queue: queue.map(Queue.init),
                writtenSamples: String(writtenSamples), coverage: coverage, validity: validity, observations: observations)
        }
    }
    public var snapshot: Snapshot {
        lock.withLock {
            if let closedSnapshot { return closedSnapshot }
            return makeSnapshot(at: stamp(), terminal: nil)
        }
    }
    /// Call after stop resolves. It neither queries nor waits for media owners.
    @discardableResult public func close(snapshot: RecordingSessionSnapshot) -> Snapshot {
        lock.withLock {
            if let closedSnapshot { return closedSnapshot }
            let terminal = Terminal(state: String(describing: snapshot.state), failure: snapshot.failure.map(FailureCode.init),
                                    writtenSamples: String(snapshot.writtenSamples), queue: Queue(snapshot.queue))
            let closed = makeSnapshot(at: stamp(), terminal: terminal)
            closedSnapshot = closed
            return closed
        }
    }

    // All helpers run under lock. Unknown timing propagates; it never becomes zero.
    private func stamp() -> Double? {
        let instant = now()
        if instant < previous { validity.timingValid = false }
        previous = instant
        return relative(instant)
    }
    private func relative(_ instant: ContinuousClock.Instant) -> Double? {
        let components = anchor.duration(to: instant).components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard value.isFinite, (0...1e12).contains(value) else { validity.timingValid = false; return nil }
        return validity.timingValid ? value : nil
    }
    private func elapsed(_ start: Double?, _ end: Double?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return end - start
    }
    private func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        let result = lhs + rhs
        guard result.isFinite, result <= 1e12 else { validity.timingValid = false; return nil }
        return result
    }
    private func maximum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }; return max(lhs, rhs)
    }
    static func saturatedIncrement(_ value: UInt64) -> (value: UInt64, overflow: Bool) {
        let (next, overflow) = value.addingReportingOverflow(1)
        return (overflow ? .max : next, overflow)
    }
    private func increment(_ value: inout UInt64) {
        let result = Self.saturatedIncrement(value)
        value = result.value
        if result.overflow { validity.counterOverflow = true }
    }
    private func observations(at time: Double?) -> Observations {
        var active = consumer
        if var current = active {
            if current.phase == .append {
                let partial = elapsed(current.phaseStarted, time)
                current.appendElapsed = sum(current.appendElapsed, partial)
                current.appendMaximum = maximum(current.appendMaximum, partial)
            } else if current.phase == .retryWait {
                current.retryWaitElapsed = sum(current.retryWaitElapsed, elapsed(current.phaseStarted, time))
            }
            current.readinessElapsed = elapsed(current.readinessSince, time)
            active = current
        }
        return Observations(
            producers: History(completed: producers, oldestRetainedTime: producers.first?.generationStart, omittedCount: String(producerOmitted)),
            consumers: History(completed: consumers, oldestRetainedTime: consumers.first?.started, omittedCount: String(consumerOmitted)),
            persistences: History(completed: persistences, oldestRetainedTime: persistences.compactMap(\.started).min(), omittedCount: String(persistenceOmitted)),
            activeProducer: producer, activeConsumer: active,
            activePersistences: activePersistences.map { entry in
                var partial = entry; partial.elapsed = elapsed(entry.started, time); return partial
            }, omittedActivePersistences: String(activeOmitted),
            audioAccepted: String(audioAccepted), audioRejected: String(audioRejected),
            videoAccepted: String(videoAccepted), videoRejected: String(videoRejected))
    }
    private func makeSnapshot(at time: Double?, terminal: Terminal?) -> Snapshot {
        let observations = observations(at: time)
        return Snapshot(recordingID: recordingID, queueLimits: queueLimits, profile: profile, coverage: coverage,
                        validity: validity, observedAt: time, observations: observations,
                        firstFailure: firstFailure, terminal: terminal, closed: terminal != nil)
    }
}
#endif
