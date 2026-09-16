import Foundation

/// One authenticated, locally matched receiver snapshot. Freshness is necessary,
/// but not sufficient, for capacity: a policy must also prove causal progress,
/// sender acceptance, current media health and the candidate's measured cost.
public struct WorkerReceiverProbeFreshness: Sendable {
    public let expected: WorkerReceiverProbeExpectation
    public let workerEpoch: String
    public let workerAttempt: Int
    public let publication: WorkerPublication
    public let snapshot: ReceiverProbeSnapshot

    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    private static let maximumAge: Duration = .milliseconds(maximumSafeInteger)
    private let receivedAt: ContinuousClock.Instant
    private let ageAtReceipt: Duration
    private let lastDeliveryAgeAtSnapshot: Duration?
    private let statusFreshness: WorkerStatusFreshness

    public init?(response: WorkerMediaStatusResponse, expected: WorkerReceiverProbeExpectation,
                 receivedAt: ContinuousClock.Instant, requestDuration: Duration) {
        let status = response.status
        guard requestDuration >= .zero,
              status.gameId == expected.gameId, status.generation == expected.generation,
              status.workerId == expected.workerId,
              let publication = status.validatedPublication,
              publication.publishingAttemptId == expected.publishingAttemptId,
              let workerEpoch = status.workerEpoch, let observation = status.observation,
              let report = status.receiverProbe, let validated = report.snapshot.validated,
              report.snapshot.id == expected.probeId,
              validated.generation == expected.publishingGeneration,
              report.snapshot.bitRate == expected.bitRate,
              report.ageUpperBoundMs.isFinite, report.ageUpperBoundMs >= 0,
              report.ageUpperBoundMs.rounded(.towardZero) == report.ageUpperBoundMs,
              report.ageUpperBoundMs <= Double(Self.maximumSafeInteger) else { return nil }
        let age = Duration.milliseconds(Int64(report.ageUpperBoundMs))
        guard requestDuration <= Self.maximumAge - age else { return nil }
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        guard freshness.isFresh(at: receivedAt) else { return nil }
        self.expected = expected; self.workerEpoch = workerEpoch; self.workerAttempt = observation.attempt
        self.publication = publication; self.snapshot = report.snapshot
        self.receivedAt = receivedAt; self.ageAtReceipt = age + requestDuration
        self.statusFreshness = freshness
        // Validated timestamps are bounded to one day, well inside Int64 even on Watch.
        self.lastDeliveryAgeAtSnapshot = validated.last.map { .nanoseconds(Int64(validated.observed - $0)) }
    }

    public func snapshotAgeUpperBound(at instant: ContinuousClock.Instant = .now) -> Duration? {
        guard instant >= receivedAt, statusFreshness.isFresh(at: instant) else { return nil }
        let residence = receivedAt.duration(to: instant)
        guard residence <= Self.maximumAge - ageAtReceipt else { return nil }
        return ageAtReceipt + residence
    }

    public func lastDeliveryAgeUpperBound(at instant: ContinuousClock.Instant = .now) -> Duration? {
        guard let deliveryAge = lastDeliveryAgeAtSnapshot, let snapshotAge = snapshotAgeUpperBound(at: instant),
              deliveryAge <= Self.maximumAge - snapshotAge else { return nil }
        return snapshotAge + deliveryAge
    }
}
