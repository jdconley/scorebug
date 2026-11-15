import Foundation

/// One read of cumulative SRT sender counters for the current connection.
public struct PublishingTransportStatistics: Equatable, Sendable {
    /// Monotonic seconds (system uptime) when sampled.
    public let sampledAt: Double
    public let sentPackets: Int64
    public let retransmittedPackets: Int64
    public let droppedPackets: Int64
    /// Timespan of unacknowledged data in the send buffer.
    public let senderBufferMilliseconds: Int
    public let rttMilliseconds: Double
    public let sendRateMbps: Double

    public init(sampledAt: Double, sentPackets: Int64, retransmittedPackets: Int64, droppedPackets: Int64,
                senderBufferMilliseconds: Int, rttMilliseconds: Double, sendRateMbps: Double) {
        self.sampledAt = sampledAt; self.sentPackets = sentPackets
        self.retransmittedPackets = retransmittedPackets; self.droppedPackets = droppedPackets
        self.senderBufferMilliseconds = senderBufferMilliseconds
        self.rttMilliseconds = rttMilliseconds; self.sendRateMbps = sendRateMbps
    }
}
