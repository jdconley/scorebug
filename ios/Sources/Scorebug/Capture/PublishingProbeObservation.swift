import Foundation
import ScorebugStreaming

/// Optional read of the existing publisher-owned probe. Never starts or renews
/// traffic; reads must remain bounded and cooperate with publisher teardown.
protocol PublishingProbeObserving: Sendable {
    func probeObservation() async -> PublishingProbeObservation?
}
struct PublishingProbeObservation: Sendable {
    var id: UUID
    var publishingGeneration: UInt64
    var bitRate: Int
    var startedAt: Double
    var leaseDeadline: Double
    var acceptedPayloadBytes: UInt64
    var lastAcceptedAt: Double?
    var reason: String?
    var stage: Int?
    var permitsCurrentOwner: (@Sendable (UUID, UInt64, Int?) -> Bool)?
    func isActive(at now: Double) -> Bool {
        guard stage.map({ (1...32).contains($0) }) ?? true,
              permitsCurrentOwner?(id, publishingGeneration, stage) == true else { return false }
        guard reason == nil, publishingGeneration > 0, (1...2_000_000).contains(bitRate),
              now.isFinite, startedAt.isFinite, startedAt >= 0, now >= startedAt, now - startedAt < 60,
              leaseDeadline.isFinite, leaseDeadline > now, leaseDeadline <= startedAt + 60.3,
              acceptedPayloadBytes <= 16 * 1024 * 1024, acceptedPayloadBytes % 1316 == 0,
              (acceptedPayloadBytes == 0) == (lastAcceptedAt == nil) else { return false }
        return lastAcceptedAt.map { $0.isFinite && $0 >= startedAt && $0 <= now && $0 < leaseDeadline } ?? true
    }
    init(_ sample: PublishingBandwidthProbeSnapshot) {
        self.init(id: sample.id, publishingGeneration: sample.publishingGeneration, bitRate: sample.bitRate,
            startedAt: sample.startedAt, leaseDeadline: sample.leaseDeadline, acceptedPayloadBytes: sample.acceptedPayloadBytes,
            lastAcceptedAt: sample.lastAcceptedAt, reason: sample.reason?.rawValue,
            stage: sample.stage.flatMap(Int.init(exactly:)), permitsCurrentOwner: { id, generation, stage in
                sample.authority?.permits(id: id, generation: generation,
                    stage: stage.flatMap(UInt32.init(exactly:))) == true
            })
    }
    init(id: UUID, publishingGeneration: UInt64, bitRate: Int, startedAt: Double, leaseDeadline: Double,
         acceptedPayloadBytes: UInt64, lastAcceptedAt: Double?, reason: String?, stage: Int? = nil,
         permitsCurrentOwner: (@Sendable (UUID, UInt64, Int?) -> Bool)? = nil) {
        self.id = id; self.publishingGeneration = publishingGeneration; self.bitRate = bitRate
        self.startedAt = startedAt; self.leaseDeadline = leaseDeadline; self.acceptedPayloadBytes = acceptedPayloadBytes
        self.lastAcceptedAt = lastAcceptedAt; self.reason = reason
        self.stage = stage; self.permitsCurrentOwner = permitsCurrentOwner
    }
}
extension SRTMediaPublisher: PublishingProbeObserving {
    func probeObservation() async -> PublishingProbeObservation? { await bandwidthProbeSnapshot().map(PublishingProbeObservation.init) }
}

struct PublishingProbeReadTiming: Sendable {
    let requestStartedAt: Double
    let responseReceivedAt: Double
    let nativeReadStartedAt: Double
    let nativeReadFinishedAt: Double
    let evaluatedAt: Double
}
