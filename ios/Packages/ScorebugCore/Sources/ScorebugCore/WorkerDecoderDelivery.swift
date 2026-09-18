import Foundation

/// Authenticated response binding plus a bounded complete arrival history. This
/// does not establish expected source frames, on-time delivery or recovery health.
public struct WorkerDecoderDeliveryFreshness: Sendable {
    public struct Context: Equatable, Sendable {
        public let gameId: String
        public let generation: Int
        public let workerId: String
        public let workerEpoch: String
        public let attempt: Int
        public let publication: WorkerPublication
    }
    public let receiptID: UUID
    public let context: Context
    public let snapshot: DecoderDeliverySnapshot
    public let sampledAtMs: Double
    public let sampleTimeBounds: DeliverySampleTimeBounds?
    fileprivate let receivedAt: ContinuousClock.Instant
    fileprivate let ageAtReceipt: Duration
    fileprivate let statusFreshness: WorkerStatusFreshness
    fileprivate static let maximumAge = Duration.milliseconds(DecoderDeliveryPacket.maximum)
    public func sampleAgeUpperBound(at instant: ContinuousClock.Instant = .now) -> Duration? {
        guard instant >= receivedAt, statusFreshness.isFresh(at: instant) else { return nil }
        let residence = receivedAt.duration(to: instant)
        guard residence <= Self.maximumAge - ageAtReceipt else { return nil }
        return ageAtReceipt + residence
    }
}

/// One local publishing attempt owns this tracker. Scope changes require a full
/// base. Omission clears availability, but retains history for replay validation.
public struct WorkerDecoderDeliveryTracker: Sendable {
    public private(set) var latest: WorkerDecoderDeliveryFreshness?
    private var history = DecoderDeliveryHistory()
    private var context: WorkerDecoderDeliveryFreshness.Context?
    private var retired: [WorkerDecoderDeliveryFreshness.Context] = []
    private var publishingAttemptID: UUID?
    private var lastReceivedAt: ContinuousClock.Instant?
    private var lastRequestTiming: DeliveryRequestTiming?
    private var needsFull = true
    private var exhausted = false
    public init() {}
    public var cursor: DecoderDeliveryCursor? {
        guard !needsFull, let packet = history.packet else { return nil }
        return .init(scopeID: packet.scopeID, lastOrdinal: packet.lastOrdinal)
    }
    public mutating func reset() { self = .init() }
    public mutating func unavailable() { latest = nil; needsFull = true }
    public mutating func expire(at instant: ContinuousClock.Instant = .now) {
        if latest?.sampleAgeUpperBound(at: instant) == nil { unavailable() }
    }
    @discardableResult public mutating func observe(response: WorkerMediaStatusResponse,
        expectedPublishingAttemptID: UUID, receivedAt: ContinuousClock.Instant,
        requestDuration: Duration, requestTiming: DeliveryRequestTiming? = nil) -> WorkerDecoderDeliveryFreshness? {
        if publishingAttemptID != expectedPublishingAttemptID { reset(); publishingAttemptID = expectedPublishingAttemptID }
        let priorProof = latest
        latest = nil
        let status = response.status
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        guard !exhausted, requestDuration >= .zero, freshness.isFresh(at: receivedAt),
              lastReceivedAt.map({ receivedAt >= $0 }) ?? true,
              status.state == .producingOutput, let publication = status.validatedPublication,
              publication.publishingAttemptId == expectedPublishingAttemptID.uuidString.lowercased(),
              let observation = status.observation, observation.decodedVideo?.clock == "mpegts-pts-90k-v1",
              let workerId = status.workerId, let workerEpoch = status.workerEpoch,
              let packet = observation.decoderDelivery, packet.isValid else { unavailable(); return nil }
        if let requestTiming {
            let duration = requestDuration.components
            let durationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            // The uptime reads enclose the ContinuousClock reads; allow only
            // floating-point subtraction roundoff when comparing their spans.
            let roundoff = 2 * Double.ulpOfOne * max(1, requestTiming.receivedAt)
            guard durationSeconds <= requestTiming.receivedAt - requestTiming.startedAt + roundoff else {
                unavailable(); return nil
            }
            if let previousTiming = lastRequestTiming {
                guard requestTiming.startedAt >= previousTiming.startedAt,
                      requestTiming.receivedAt >= previousTiming.receivedAt else { unavailable(); return nil }
            }
        }
        lastReceivedAt = receivedAt
        let binding = WorkerDecoderDeliveryFreshness.Context(gameId: status.gameId, generation: status.generation,
            workerId: workerId, workerEpoch: workerEpoch, attempt: observation.attempt, publication: publication)
        if context != binding {
            guard !retired.contains(binding) else { unavailable(); return nil }
            guard retired.count < 64 else { exhausted = true; unavailable(); return nil }
            if let context { retired.append(context) }
            context = binding; history = .init(); needsFull = true
        }
        let previousSample = history.packet?.sampledAtMs
        do {
            if needsFull && !packet.isFull { throw DecoderDeliveryHistory.Failure.incomplete }
            try history.accept(packet)
        } catch { unavailable(); return nil }
        guard packet.invalidReason == nil, !packet.ended,
              let snapshot = history.snapshot,
              let serverAge = status.decoderDeliveryAgeUpperBoundMs,
              serverAge.isFinite, serverAge >= 0, serverAge <= Double(DecoderDeliveryPacket.maximum),
              serverAge.rounded(.down) == serverAge else { unavailable(); return nil }
        let base = Duration.milliseconds(Int64(serverAge)), maximum = WorkerDecoderDeliveryFreshness.maximumAge
        guard requestDuration <= maximum - base else { unavailable(); return nil }
        var age = base + requestDuration
        var sampleTimeBounds = requestTiming.flatMap {
            DeliverySampleTimeBounds(lower: max(0, $0.startedAt - serverAge / 1000), upper: $0.receivedAt)
        }
        if previousSample == packet.sampledAtMs {
            guard let priorProof, priorProof.context == binding, priorProof.snapshot.scopeID == snapshot.scopeID,
                  let previousAge = priorProof.sampleAgeUpperBound(at: receivedAt) else { unavailable(); return nil }
            age = max(age, previousAge)
            // A frozen sample cannot acquire or widen an anchor on a later receipt.
            sampleTimeBounds = priorProof.sampleTimeBounds
        }
        let value = WorkerDecoderDeliveryFreshness(receiptID: UUID(), context: binding, snapshot: snapshot,
            sampledAtMs: packet.sampledAtMs, sampleTimeBounds: sampleTimeBounds,
            receivedAt: receivedAt, ageAtReceipt: age, statusFreshness: freshness)
        if let requestTiming { lastRequestTiming = requestTiming }
        latest = value; needsFull = false
        return value
    }
}
