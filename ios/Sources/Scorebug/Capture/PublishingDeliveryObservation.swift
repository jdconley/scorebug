import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Classifies a caller-selected complete source window using the currently owned
/// authenticated delivery proof. The owner must supply its current tracker value,
/// rather than retaining a proof across worker/publication changes. This does not
/// schedule windows or authorize quality changes. All local scalar times use the
/// capture/encoder monotonic clock; `instant` supplies delivery-proof residence.
struct PublishingDeliveryObservation: Sendable {
    enum Failure: Error, Equatable { case ownership, configuration, time, freshness, source, contradiction }
    let source: PublishingDeliverySourceWindow
    let delivery: WorkerDecoderDeliveryFreshness
    let appliedRevision: UInt64
    let result: DeliveryDeadlineResult

    static func classify(history: VideoSourceHistorySnapshot, clock: PublishingClockObservation,
                         applied: PublishingQualityTelemetry.Applied,
                         diagnostics: PublishingQualityTelemetry.Diagnostics,
                         delivery: WorkerDecoderDeliveryFreshness,
                         windowStart: Double, windowEnd: Double, at now: Double,
                         instant: ContinuousClock.Instant, maximumSampleAge: Double,
                         latencyBudget: Double) throws -> Self {
        let receipt = applied.receipt, context = delivery.context
        guard diagnostics.isPublishing, !clock.isClosed, clock.scope == history.scope,
              history.scope.publishingAttemptID == applied.attemptID,
              history.scope.matchID == context.gameId, history.scope.broadcastGeneration == context.generation,
              context.publication.publishingAttemptId == applied.attemptID.uuidString.lowercased(),
              diagnostics.clock == clock.transportClock,
              clock.transportClock.publishingGeneration == receipt.publishingGeneration,
              let ingress = diagnostics.ingress, !ingress.isClosed, ingress.scope == history.scope,
              let current = diagnostics.receipt,
              current.publishingGeneration == receipt.publishingGeneration,
              current.configuration == receipt.configuration, current.acceptedAt == receipt.acceptedAt,
              current.lastSubmittedSourcePTS == receipt.lastSubmittedSourcePTS else { throw Failure.ownership }
        guard receipt.configuration.bitRate == applied.settings.videoBitrate else { throw Failure.configuration }
        guard now.isFinite, (0...1e12).contains(now), windowEnd <= now,
              history.capture.last.map({ $0.observedAt <= now }) == true,
              history.encoded.last.map({ $0.observedAt <= now }) == true else { throw Failure.time }
        guard let age = delivery.sampleAgeUpperBound(at: instant), age >= .zero else { throw Failure.freshness }
        let seconds = Double(age.components.seconds) + Double(age.components.attoseconds) / 1e18
        guard maximumSampleAge.isFinite, maximumSampleAge > 0, maximumSampleAge <= 5,
              seconds <= maximumSampleAge else { throw Failure.freshness }
        guard let relayOrigin = Int64(context.publication.clock.originPTS),
              let anchor = delivery.snapshot.arrivals.last?.pts,
              let source = PublishingDeliverySourceWindow.match(history: history, clock: clock.transportClock,
                receipt: receipt, acknowledgedAt: applied.acknowledgedAt, windowStart: windowStart, windowEnd: windowEnd,
                relayOriginPTS: relayOrigin, anchorDecodedPTS: anchor) else { throw Failure.source }
        let arrived = Set(delivery.snapshot.arrivals.map(\.pts))
        guard source.frames.allSatisfy({ $0.wasEncoded || !arrived.contains($0.decodedPTS) }) else { throw Failure.contradiction }
        let result = try DeliveryDeadlineClassifier.classify(timeline: delivery.snapshot,
            expectedScopeID: delivery.snapshot.scopeID,
            frames: source.frames.map { .init(pts: $0.decodedPTS, capturedAt: $0.capturedAt) },
            windowStart: windowStart, windowEnd: windowEnd, evaluatedAt: now,
            sampleAgeUpperBound: seconds, maximumSampleAge: maximumSampleAge, latencyBudget: latencyBudget)
        return .init(source: source, delivery: delivery, appliedRevision: applied.revision, result: result)
    }
}
