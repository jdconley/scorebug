import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Historical source correspondence, not current health or destination receipt.
struct WorkerSourceIntervalObservation: Sendable {
    let interval: PublishingSourceInterval
    let nativeClock: PublishingTransportClock
    let workerId: String
    let workerEpoch: String
    let workerAttempt: Int
    let publication: WorkerPublication
    let previousSequence: Int64
    let sequence: Int64
    let previousDecodedPTS: Int64
    let firstDecodedPTS: Int64
    let lastDecodedPTS: Int64
    let freshness: WorkerDecodedVideoFreshness
}

struct WorkerSourceIntervalTracker {
    enum GapReason: String { case acquisition, missingEvidence, scopeChanged, sequenceGap, contradiction, rewind, invalidWindow, unmatchedHistory, expired }
    private(set) var latest: WorkerSourceIntervalObservation?
    private(set) var gapReason: GapReason? = .acquisition
    private struct Scope: Equatable {
        let native: VideoFrameObservationScope
        let clock: PublishingTransportClock
        let workerId: String
        let workerEpoch: String
        let workerAttempt: Int
        let publication: WorkerPublication
    }
    private var scope: Scope?
    private var lastWindow: DecodedVideoWindow?
    private var baseline: DecodedVideoWindow?
    private var statusFreshness: WorkerStatusFreshness?

    mutating func observe(response: WorkerMediaStatusResponse, history: VideoSourceHistorySnapshot?,
                          clock: PublishingClockObservation?, receivedAt: ContinuousClock.Instant,
                          requestDuration: Duration) -> WorkerSourceIntervalObservation? {
        let status = response.status
        guard let history, !history.isClosed, history.invalidity == nil,
              let clock, !clock.isClosed, clock.scope == history.scope,
              history.scope.matchID == status.gameId, history.scope.broadcastGeneration == status.generation,
              let publication = status.validatedPublication,
              publication.publishingAttemptId == history.scope.publishingAttemptID.uuidString.lowercased(),
              let workerEpoch = status.workerEpoch, let workerId = status.workerId,
              let decoded = status.observation?.decodedVideo, decoded.usesTransportClock,
              let helper = WorkerDecodedVideoFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration),
              let origin = Int64(publication.clock.originPTS) else { reset(.missingEvidence); return nil }

        if statusFreshness?.isFresh(at: receivedAt) == false { reset(.expired) }

        let nextScope = Scope(native: history.scope, clock: clock.transportClock,
            workerId: workerId, workerEpoch: workerEpoch, workerAttempt: helper.attempt, publication: publication)
        if scope != nextScope {
            let reason: GapReason = scope == nil ? .acquisition : .scopeChanged
            reset(reason)
            scope = nextScope
        }
        statusFreshness = WorkerStatusFreshness(response: response, receivedAt: receivedAt, requestDuration: requestDuration)
        if let latest, latest.freshness.ageUpperBound(at: receivedAt) == nil {
            self.latest = nil; gapReason = .expired
        }
        let window = helper.completed
        if let lastWindow {
            if window.sequence < lastWindow.sequence {
                baseline = nil; latest = nil; gapReason = .rewind
                return nil
            }
            if window.sequence == lastWindow.sequence {
                if !Self.sameContents(window, lastWindow) {
                    baseline = nil; latest = nil; gapReason = .contradiction
                }
                return latest
            }
        }
        let previous = baseline
        lastWindow = window
        latest = nil
        guard window.freshFrames > 0, window.duplicateFrames == 0, window.reorderedFrames == 0,
              let first = window.firstPTS, let last = window.lastPTS else {
            baseline = nil; gapReason = .invalidWindow; return nil
        }
        baseline = window
        guard let previous, let previousPTS = previous.lastPTS else { return nil }
        guard window.sequence == previous.sequence + 1 else { gapReason = .sequenceGap; return nil }
        guard let interval = PublishingSourceInterval.match(history: history, clock: clock.transportClock,
            relayOriginPTS: origin, previousDecodedPTS: previousPTS, firstDecodedPTS: first,
            lastDecodedPTS: last, decodedFrames: window.freshFrames) else {
            gapReason = .unmatchedHistory; return nil
        }
        let observation = WorkerSourceIntervalObservation(interval: interval, nativeClock: clock.transportClock, workerId: workerId,
            workerEpoch: workerEpoch, workerAttempt: helper.attempt, publication: publication,
            previousSequence: previous.sequence, sequence: window.sequence,
            previousDecodedPTS: previousPTS, firstDecodedPTS: first, lastDecodedPTS: last, freshness: helper)
        latest = observation
        gapReason = nil
        return observation
    }

    /// Decoder window age is separate from the report lease. Accepted historical
    /// anchors survive normal age progression between five-second windows. An
    /// expired report lease discards both current evidence and that anchor.
    mutating func expire(at instant: ContinuousClock.Instant) {
        if statusFreshness?.isFresh(at: instant) == false { reset(.expired) }
        else if let latest, latest.freshness.ageUpperBound(at: instant) == nil {
            self.latest = nil; gapReason = .expired
        }
    }

    mutating func clear() { reset(.missingEvidence) }

    private mutating func reset(_ reason: GapReason) {
        scope = nil; lastWindow = nil; baseline = nil; latest = nil; statusFreshness = nil; gapReason = reason
    }

    private static func sameContents(_ first: DecodedVideoWindow, _ second: DecodedVideoWindow) -> Bool {
        var first = first, second = second
        first.ageMs = 0; second.ageMs = 0
        return first == second
    }
}
