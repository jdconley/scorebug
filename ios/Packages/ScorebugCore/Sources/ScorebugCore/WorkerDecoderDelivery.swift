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
    public enum UnavailabilityReason: String, Sendable {
        case statusUnavailable, statusRequestFailed, contextMismatch, sampleExpired, statusStale, invalidRequestDuration, receiptRegressed
        case workerNotProducing, publicationUnavailable, publishingAttemptMismatch, decoderClockMismatch
        case workerIdentityMissing, packetMissing, packetMalformed, invalidRequestTiming, requestTimingRegressed
        case retiredContext, retiredContextLimit, fullBaseRequired, historyRejected, receiverInvalidated, receiverEnded
        case sampleAgeInvalid, requestTooOld, frozenSampleWithoutProof
    }
    public private(set) var latest: WorkerDecoderDeliveryFreshness?
    public private(set) var unavailabilityReason: UnavailabilityReason?
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
    public mutating func unavailable(reason: UnavailabilityReason = .statusUnavailable) {
        latest = nil; needsFull = true; unavailabilityReason = reason
    }
    private mutating func reject(_ reason: UnavailabilityReason) -> WorkerDecoderDeliveryFreshness? {
        unavailable(reason: reason); return nil
    }
    public mutating func expire(at instant: ContinuousClock.Instant = .now) {
        if let latest, latest.sampleAgeUpperBound(at: instant) == nil { unavailable(reason: .sampleExpired) }
    }
    @discardableResult public mutating func observe(response: WorkerMediaStatusResponse,
        expectedPublishingAttemptID: UUID, receivedAt: ContinuousClock.Instant,
        requestDuration: Duration, requestTiming: DeliveryRequestTiming? = nil) -> WorkerDecoderDeliveryFreshness? {
        if publishingAttemptID != expectedPublishingAttemptID { reset(); publishingAttemptID = expectedPublishingAttemptID }
        let priorProof = latest
        latest = nil
        let status = response.status
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        guard !exhausted else { return reject(.retiredContextLimit) }
        guard requestDuration >= .zero else { return reject(.invalidRequestDuration) }
        guard freshness.isFresh(at: receivedAt) else { return reject(.statusStale) }
        guard lastReceivedAt.map({ receivedAt >= $0 }) ?? true else { return reject(.receiptRegressed) }
        guard status.state == .producingOutput else { return reject(.workerNotProducing) }
        guard let publication = status.validatedPublication else { return reject(.publicationUnavailable) }
        guard publication.publishingAttemptId == expectedPublishingAttemptID.uuidString.lowercased() else { return reject(.publishingAttemptMismatch) }
        guard let observation = status.observation, observation.decodedVideo?.clock == "mpegts-pts-90k-v1" else { return reject(.decoderClockMismatch) }
        guard let workerId = status.workerId, let workerEpoch = status.workerEpoch else { return reject(.workerIdentityMissing) }
        guard let packet = observation.decoderDelivery else { return reject(.packetMissing) }
        guard packet.isValid else { return reject(.packetMalformed) }
        if let requestTiming {
            let duration = requestDuration.components
            let durationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            // The uptime reads enclose the ContinuousClock reads; allow only
            // floating-point subtraction roundoff when comparing their spans.
            let roundoff = 2 * Double.ulpOfOne * max(1, requestTiming.receivedAt)
            guard durationSeconds <= requestTiming.receivedAt - requestTiming.startedAt + roundoff else {
                return reject(.invalidRequestTiming)
            }
            if let previousTiming = lastRequestTiming {
                guard requestTiming.startedAt >= previousTiming.startedAt,
                      requestTiming.receivedAt >= previousTiming.receivedAt else { return reject(.requestTimingRegressed) }
            }
        }
        lastReceivedAt = receivedAt
        let binding = WorkerDecoderDeliveryFreshness.Context(gameId: status.gameId, generation: status.generation,
            workerId: workerId, workerEpoch: workerEpoch, attempt: observation.attempt, publication: publication)
        if context != binding {
            guard !retired.contains(binding) else { return reject(.retiredContext) }
            guard retired.count < 64 else { exhausted = true; return reject(.retiredContextLimit) }
            if let context { retired.append(context) }
            context = binding; history = .init(); needsFull = true
        }
        let previousSample = history.packet?.sampledAtMs
        do {
            if needsFull && !packet.isFull { return reject(.fullBaseRequired) }
            try history.accept(packet)
        } catch { return reject(.historyRejected) }
        guard packet.invalidReason == nil else { return reject(.receiverInvalidated) }
        guard !packet.ended else { return reject(.receiverEnded) }
        guard let snapshot = history.snapshot,
              let serverAge = status.decoderDeliveryAgeUpperBoundMs,
              serverAge.isFinite, serverAge >= 0, serverAge <= Double(DecoderDeliveryPacket.maximum),
              serverAge.rounded(.down) == serverAge else { return reject(.sampleAgeInvalid) }
        let base = Duration.milliseconds(Int64(serverAge)), maximum = WorkerDecoderDeliveryFreshness.maximumAge
        guard requestDuration <= maximum - base else { return reject(.requestTooOld) }
        var age = base + requestDuration
        var sampleTimeBounds = requestTiming.flatMap {
            DeliverySampleTimeBounds(lower: max(0, $0.startedAt - serverAge / 1000), upper: $0.receivedAt)
        }
        if previousSample == packet.sampledAtMs {
            guard let priorProof, priorProof.context == binding, priorProof.snapshot.scopeID == snapshot.scopeID,
                  let previousAge = priorProof.sampleAgeUpperBound(at: receivedAt) else { return reject(.frozenSampleWithoutProof) }
            age = max(age, previousAge)
            // A frozen sample cannot acquire or widen an anchor on a later receipt.
            sampleTimeBounds = priorProof.sampleTimeBounds
        }
        let value = WorkerDecoderDeliveryFreshness(receiptID: UUID(), context: binding, snapshot: snapshot,
            sampledAtMs: packet.sampledAtMs, sampleTimeBounds: sampleTimeBounds,
            receivedAt: receivedAt, ageAtReceipt: age, statusFreshness: freshness)
        if let requestTiming { lastRequestTiming = requestTiming }
        latest = value; needsFull = false; unavailabilityReason = nil
        return value
    }
}
