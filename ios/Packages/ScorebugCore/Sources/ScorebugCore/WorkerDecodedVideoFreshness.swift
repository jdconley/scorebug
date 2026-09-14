import Foundation

/// Conservative age of one immutable worker decoder window and its attempt scope.
/// Age does not establish frame progress, output delivery, or source-window alignment.
public struct WorkerDecodedVideoFreshness: Sendable {
    public let gameId: String
    public let generation: Int
    public let workerId: String
    public let attempt: Int
    public let completed: DecodedVideoWindow

    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    private static let maximumAge: Duration = .milliseconds(maximumSafeInteger)
    private let receivedAt: ContinuousClock.Instant
    private let ageAtReceipt: Duration
    private let statusFreshness: WorkerStatusFreshness

    public init?(response: WorkerMediaStatusResponse, receivedAt: ContinuousClock.Instant, requestDuration: Duration) {
        let status = response.status
        guard requestDuration >= .zero,
              status.state == .producingOutput,
              let workerId = status.workerId,
              workerId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let observation = status.observation,
              observation.gameId == status.gameId, observation.generation == status.generation,
              observation.state == .producingOutput,
              let decoded = observation.decodedVideo, !decoded.ended, decoded.invalidReason == nil,
              let completed = decoded.completed, Self.isValid(completed),
              let serverAge = status.decodedVideoAgeUpperBoundMs,
              serverAge.isFinite, serverAge >= 0, serverAge.rounded(.towardZero) == serverAge,
              serverAge <= Double(Self.maximumSafeInteger), serverAge >= completed.ageMs else { return nil }

        let baseAge = Duration.milliseconds(Int64(serverAge))
        // Check before addition: Double sums lose submillisecond overflow near the wire limit.
        guard requestDuration <= Self.maximumAge - baseAge else { return nil }
        let freshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        guard freshness.isFresh(at: receivedAt) else { return nil }
        self.gameId = status.gameId; self.generation = status.generation
        self.workerId = workerId; self.attempt = observation.attempt; self.completed = completed
        self.receivedAt = receivedAt; self.ageAtReceipt = baseAge + requestDuration
        self.statusFreshness = freshness
    }

    public func ageUpperBound(at instant: ContinuousClock.Instant = .now) -> Duration? {
        guard instant >= receivedAt, statusFreshness.isFresh(at: instant) else { return nil }
        let residence = receivedAt.duration(to: instant)
        guard residence <= Self.maximumAge - ageAtReceipt else { return nil }
        return ageAtReceipt + residence
    }

    private static func isValid(_ window: DecodedVideoWindow) -> Bool {
        guard window.valid, window.sequence > 0, window.sequence <= maximumSafeInteger,
              window.durationMs == 5000,
              window.ageMs.isFinite, window.ageMs >= 0, window.ageMs <= Double(maximumSafeInteger) else { return false }
        var total: Int64 = 0
        for count in [window.freshFrames, window.duplicateFrames, window.reorderedFrames] {
            guard count >= 0, count <= maximumSafeInteger - total else { return false }
            total += count
        }
        for pts in [window.firstPTS, window.lastPTS].compactMap({ $0 }) {
            guard pts >= -maximumSafeInteger, pts <= maximumSafeInteger else { return false }
        }
        if window.freshFrames == 0 { return window.firstPTS == nil && window.lastPTS == nil }
        guard let first = window.firstPTS, let last = window.lastPTS else { return false }
        return window.freshFrames == 1 ? first == last : first < last
    }
}
