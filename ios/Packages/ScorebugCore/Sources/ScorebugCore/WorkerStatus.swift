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

    public init(gameId: String, generation: Int, state: WorkerState, reason: WorkerReason?, attempt: Int,
                frame: Int?, outTimeUs: Int?, scoreRevision: Int?) {
        self.gameId = gameId; self.generation = generation; self.state = state; self.reason = reason
        self.attempt = attempt; self.frame = frame; self.outTimeUs = outTimeUs; self.scoreRevision = scoreRevision
    }
}

/// Summary worker state for display. Additional server fields are ignored.
public struct WorkerMediaStatus: Codable, Equatable, Sendable {
    public var gameId: String
    public var generation: Int
    public var workerId: String?
    public var state: WorkerMediaState
    public var observation: WorkerObservation?
    public var observedAt: String?
    public var expiresAt: String?

    public init(gameId: String, generation: Int, workerId: String?, state: WorkerMediaState,
                observation: WorkerObservation?, observedAt: String?, expiresAt: String?) {
        self.gameId = gameId; self.generation = generation; self.workerId = workerId; self.state = state
        self.observation = observation; self.observedAt = observedAt; self.expiresAt = expiresAt
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
