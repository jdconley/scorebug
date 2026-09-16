import Foundation

/// Scalar SRT transport evidence. Sent bytes include retransmissions and transport
/// overhead; neither send rate nor estimated bandwidth proves usable video capacity.
public struct PublishingTransportStatistics: Equatable, Sendable {
    public let publishingGeneration: UInt64
    public let sampledAt: Double
    public let elapsedMilliseconds: Int64
    public let sentBytes: UInt64
    public let retransmittedBytes: UInt64
    public let droppedPackets: Int32
    public let rttMilliseconds: Double
    public let estimatedBandwidthMbps: Double
    public let senderBufferedBytes: Int32
    public let senderBufferMilliseconds: Int32
    public let availableSenderBytes: Int32

    public init?(publishingGeneration: UInt64, sampledAt: Double, elapsedMilliseconds: Int64,
                 sentBytes: UInt64, retransmittedBytes: UInt64, droppedPackets: Int32,
                 rttMilliseconds: Double, estimatedBandwidthMbps: Double, senderBufferedBytes: Int32,
                 senderBufferMilliseconds: Int32, availableSenderBytes: Int32) {
        guard publishingGeneration > 0, sampledAt.isFinite, (0...1e12).contains(sampledAt),
              elapsedMilliseconds >= 0, retransmittedBytes <= sentBytes, droppedPackets >= 0,
              rttMilliseconds.isFinite, rttMilliseconds >= 0,
              estimatedBandwidthMbps.isFinite, estimatedBandwidthMbps >= 0,
              senderBufferedBytes >= 0, senderBufferMilliseconds >= 0, availableSenderBytes >= 0 else { return nil }
        self.publishingGeneration = publishingGeneration; self.sampledAt = sampledAt
        self.elapsedMilliseconds = elapsedMilliseconds; self.sentBytes = sentBytes
        self.retransmittedBytes = retransmittedBytes; self.droppedPackets = droppedPackets
        self.rttMilliseconds = rttMilliseconds; self.estimatedBandwidthMbps = estimatedBandwidthMbps
        self.senderBufferedBytes = senderBufferedBytes; self.senderBufferMilliseconds = senderBufferMilliseconds
        self.availableSenderBytes = availableSenderBytes
    }
}

public struct PublishingTransportStatisticsSnapshot: Equatable, Sendable {
    public let latest: PublishingTransportStatistics?
    public let window: PublishingTransportWindow?
    public func freshWindow(at uptime: Double, maximumAge: Double = 2) -> PublishingTransportWindow? {
        guard freshSample(at: uptime, maximumAge: maximumAge) != nil else { return nil }
        return window
    }
    public let isQuarantined: Bool
    public let isClosed: Bool
    public func freshSample(at uptime: Double, maximumAge: Double = 2) -> PublishingTransportStatistics? {
        guard !isClosed, !isQuarantined, let latest, uptime.isFinite, (0...1e12).contains(uptime),
              maximumAge.isFinite, maximumAge >= 0, uptime >= latest.sampledAt,
              uptime - latest.sampledAt <= maximumAge else { return nil }
        return latest
    }
}

public struct PublishingTransportStatisticsTracker: Sendable {
    private var latest: PublishingTransportStatistics?
    private var history = PublishingTransportWindowHistory()
    private var quarantined = false
    private var closed = false
    public init() {}
    public var snapshot: PublishingTransportStatisticsSnapshot { .init(latest: latest, window: history.window, isQuarantined: quarantined, isClosed: closed) }
    public mutating func observe(_ sample: PublishingTransportStatistics?) {
        guard !closed, !quarantined, let sample else { return }
        if let latest {
            if sample == latest { return }
            guard sample.publishingGeneration == latest.publishingGeneration,
                  sample.sampledAt > latest.sampledAt,
                  sample.elapsedMilliseconds >= latest.elapsedMilliseconds,
                  sample.sentBytes >= latest.sentBytes,
                  sample.retransmittedBytes >= latest.retransmittedBytes,
                  sample.droppedPackets >= latest.droppedPackets,
                  sample.retransmittedBytes - latest.retransmittedBytes <= sample.sentBytes - latest.sentBytes
            else { quarantined = true; history.clear(); return }
        }
        history.append(sample)
        latest = sample
    }
    public mutating func close() { closed = true }
}
