import Foundation

/// Process observations describe encoder activity, never viewer delivery or frame freshness.
public enum WorkerState: String, Codable, Equatable, Sendable, CaseIterable {
    case idle
    case waitingSource = "waiting_source"
    case starting
    case producingOutput = "producing_output"
    case stopping, retrying, failed, closed
}

public enum WorkerReason: String, Codable, Equatable, Sendable, CaseIterable {
    case assignmentChanged = "assignment_changed"
    case sourceUnavailable = "source_unavailable"
    case outputMismatch = "output_mismatch"
    case controlUnavailable = "control_unavailable"
    case controlTimeout = "control_timeout"
    case outputTimeout = "output_timeout"
    case processExited = "process_exited"
    case scoreWriteFailed = "score_write_failed"
    case startFailed = "start_failed"
    case retryBudget = "retry_budget"
    case retryDelay = "retry_delay"
    case shutdown
}

public enum WorkerMediaState: String, Codable, Equatable, Sendable, CaseIterable {
    case notRequested = "not_requested"
    case unknown, stale, idle
    case waitingSource = "waiting_source"
    case starting
    case producingOutput = "producing_output"
    case stopping, retrying, failed, closed
}

public struct WorkerObservation: Codable, Equatable, Sendable {
    public var gameId: String
    public var generation: Int
    public var state: WorkerState
    public var reason: WorkerReason?
    public var attempt: Int
    public var frame: Int?
    public var outTimeUs: Int?
    public var scoreRevision: Int?
    public var decodedVideo: DecodedVideoSnapshot?
    public var decoderCadence: DecoderCadenceSnapshot?
    public var decoderDelivery: DecoderDeliveryPacket?
    public var processing: WorkerProcessingReport?

    public init(gameId: String, generation: Int, state: WorkerState, reason: WorkerReason?, attempt: Int,
                frame: Int?, outTimeUs: Int?, scoreRevision: Int?, decodedVideo: DecodedVideoSnapshot? = nil, processing: WorkerProcessingReport? = nil, decoderCadence: DecoderCadenceSnapshot? = nil, decoderDelivery: DecoderDeliveryPacket? = nil) {
        self.gameId = gameId; self.generation = generation; self.state = state; self.reason = reason
        self.attempt = attempt; self.frame = frame; self.outTimeUs = outTimeUs; self.scoreRevision = scoreRevision
        self.decodedVideo = decodedVideo
        self.processing = processing
        self.decoderCadence = decoderCadence
        self.decoderDelivery = decoderDelivery
    }

    private enum CodingKeys: String, CodingKey { case gameId, generation, state, reason, attempt, frame, outTimeUs, scoreRevision, decodedVideo, processing, decoderCadence, decoderDelivery }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameId = try c.decode(String.self, forKey: .gameId); generation = try c.decode(Int.self, forKey: .generation)
        state = try c.decode(WorkerState.self, forKey: .state); reason = try c.decodeIfPresent(WorkerReason.self, forKey: .reason)
        attempt = try c.decode(Int.self, forKey: .attempt); frame = try c.decodeIfPresent(Int.self, forKey: .frame)
        outTimeUs = try c.decodeIfPresent(Int.self, forKey: .outTimeUs); scoreRevision = try c.decodeIfPresent(Int.self, forKey: .scoreRevision)
        decodedVideo = try c.decodeIfPresent(DecodedVideoSnapshot.self, forKey: .decodedVideo)
        processing = try? c.decodeIfPresent(WorkerProcessingReport.self, forKey: .processing)
        decoderCadence = try? c.decodeIfPresent(DecoderCadenceSnapshot.self, forKey: .decoderCadence)
        decoderDelivery = try? c.decodeIfPresent(DecoderDeliveryPacket.self, forKey: .decoderDelivery)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gameId, forKey: .gameId)
        try container.encode(generation, forKey: .generation)
        try container.encode(state, forKey: .state)
        try container.encode(reason, forKey: .reason)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(frame, forKey: .frame)
        try container.encode(outTimeUs, forKey: .outTimeUs)
        try container.encode(scoreRevision, forKey: .scoreRevision)
        try container.encodeIfPresent(decodedVideo, forKey: .decodedVideo)
        try container.encodeIfPresent(processing, forKey: .processing)
        try container.encodeIfPresent(decoderCadence, forKey: .decoderCadence)
        try container.encodeIfPresent(decoderDelivery, forKey: .decoderDelivery)
    }
}

public struct WorkerMediaStatus: Codable, Equatable, Sendable {
    public var gameId: String
    public var generation: Int
    public var workerId: String?
    /// Opaque reporting-session identity; it does not establish freshness or readiness.
    public var workerEpoch: String?
    public var state: WorkerMediaState
    public var observation: WorkerObservation?
    public var observedAt: String?
    public var expiresAt: String?
    /// Conservative server-relative age of the completed decoded-video window.
    public var decodedVideoAgeUpperBoundMs: Double?
    /// Conservative age of the cadence snapshot, separate from its frame/window ages.
    public var decoderCadenceAgeUpperBoundMs: Double?
    public var decoderDeliveryAgeUpperBoundMs: Double?
    /// Untrusted optional wire metadata. Use validatedPublication before consuming it.
    public var publication: WorkerPublication?
    /// Optional measurement for the enclosing publication. Never use as publication identity.
    public var receiverProbe: WorkerReceiverProbe?

    public init(gameId: String, generation: Int, workerId: String?, state: WorkerMediaState,
                observation: WorkerObservation?, observedAt: String?, expiresAt: String?, decodedVideoAgeUpperBoundMs: Double? = nil,
                workerEpoch: String? = nil, publication: WorkerPublication? = nil, receiverProbe: WorkerReceiverProbe? = nil, decoderCadenceAgeUpperBoundMs: Double? = nil, decoderDeliveryAgeUpperBoundMs: Double? = nil) {
        self.gameId = gameId; self.generation = generation; self.workerId = workerId; self.state = state
        self.observation = observation; self.observedAt = observedAt; self.expiresAt = expiresAt
        self.decodedVideoAgeUpperBoundMs = decodedVideoAgeUpperBoundMs
        self.decoderCadenceAgeUpperBoundMs = decoderCadenceAgeUpperBoundMs
        self.decoderDeliveryAgeUpperBoundMs = decoderDeliveryAgeUpperBoundMs
        self.workerEpoch = workerEpoch
        self.publication = publication
        self.receiverProbe = receiverProbe
    }

    private enum CodingKeys: String, CodingKey { case gameId, generation, workerId, workerEpoch, state, observation, observedAt, expiresAt, decodedVideoAgeUpperBoundMs, publication, receiverProbe, decoderCadenceAgeUpperBoundMs, decoderDeliveryAgeUpperBoundMs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gameId = try container.decode(String.self, forKey: .gameId)
        generation = try container.decode(Int.self, forKey: .generation)
        workerId = try container.decodeIfPresent(String.self, forKey: .workerId)
        workerEpoch = try container.decodeIfPresent(String.self, forKey: .workerEpoch)
        state = try container.decode(WorkerMediaState.self, forKey: .state)
        observation = try container.decodeIfPresent(WorkerObservation.self, forKey: .observation)
        observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        decodedVideoAgeUpperBoundMs = try container.decodeIfPresent(Double.self, forKey: .decodedVideoAgeUpperBoundMs)
        decoderCadenceAgeUpperBoundMs = try? container.decodeIfPresent(Double.self, forKey: .decoderCadenceAgeUpperBoundMs)
        decoderDeliveryAgeUpperBoundMs = try? container.decodeIfPresent(Double.self, forKey: .decoderDeliveryAgeUpperBoundMs)
        // Additive metadata must never invalidate an otherwise usable status.
        publication = try? container.decodeIfPresent(WorkerPublication.self, forKey: .publication)
        receiverProbe = try? container.decodeIfPresent(WorkerReceiverProbe.self, forKey: .receiverProbe)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gameId, forKey: .gameId)
        try container.encode(generation, forKey: .generation)
        try container.encode(workerId, forKey: .workerId)
        try container.encodeIfPresent(workerEpoch, forKey: .workerEpoch)
        try container.encode(state, forKey: .state)
        try container.encode(observation, forKey: .observation)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(decodedVideoAgeUpperBoundMs, forKey: .decodedVideoAgeUpperBoundMs)
        try container.encodeIfPresent(decoderCadenceAgeUpperBoundMs, forKey: .decoderCadenceAgeUpperBoundMs)
        try container.encodeIfPresent(decoderDeliveryAgeUpperBoundMs, forKey: .decoderDeliveryAgeUpperBoundMs)
        try container.encodeIfPresent(publication, forKey: .publication)
        try container.encodeIfPresent(receiverProbe, forKey: .receiverProbe)
    }
}

public struct WorkerMediaStatusResponse: Codable, Equatable, Sendable {
    public var status: WorkerMediaStatus
    public var serverTime: String
    public init(status: WorkerMediaStatus, serverTime: String) { self.status = status; self.serverTime = serverTime }
}

/// Converts server-relative lifetime to a monotonic local deadline. Network latency
/// consumes the budget, and device wall-clock changes cannot extend an observation.
public struct WorkerStatusFreshness: Sendable {
    private let deadline: ContinuousClock.Instant

    public init(response: WorkerMediaStatusResponse, receivedAt: ContinuousClock.Instant, requestDuration: Duration) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
        let budget: Duration
        if let expiresAt = response.status.expiresAt.flatMap(date), let serverTime = date(response.serverTime) {
            budget = .seconds(max(0, min(5, expiresAt.timeIntervalSince(serverTime))))
        } else { budget = .zero }
        deadline = receivedAt.advanced(by: max(.zero, budget - max(.zero, requestDuration)))
    }

    public func isFresh(at instant: ContinuousClock.Instant = .now) -> Bool { instant < deadline }
}
