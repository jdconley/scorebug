import Foundation

/// Actual collection endpoints and exact counter deltas. Gauge means use preceding
/// samples held between collections; they cannot prove unsampled instantaneous
/// pressure, successful receiver delivery, or available video capacity.
public struct PublishingTransportWindow: Equatable, Sendable {
    public let publishingGeneration: UInt64
    public let start: Double
    public let end: Double
    public let sampleCount: Int
    public let sentBytes: UInt64
    public let retransmittedBytes: UInt64
    public let droppedPackets: Int32
    public let meanBufferedBytes: Double
    public let meanBufferMilliseconds: Double
    public let meanRTTMilliseconds: Double
    public let maximumBufferedBytes: Int32
    public let maximumBufferMilliseconds: Int32
    public let maximumRTTMilliseconds: Double
}

/// Already validated actual collections only. Caller owns generation/counter and
/// lifecycle validation. Fixed storage bounds work independently of sampling rate.
struct PublishingTransportWindowHistory: Sendable {
    private var storage = [PublishingTransportStatistics?](repeating: nil, count: 64)
    private var head = 0
    private var count = 0
    private(set) var window: PublishingTransportWindow?

    mutating func clear() {
        for index in storage.indices { storage[index] = nil }
        head = 0; count = 0; window = nil
    }
    private func sample(_ index: Int) -> PublishingTransportStatistics {
        storage[(head + index) % storage.count]!
    }
    mutating func append(_ next: PublishingTransportStatistics) {
        if count > 0, next.sampledAt - sample(count - 1).sampledAt > 2 { clear() }
        if count == storage.count {
            storage[head] = next
            head = (head + 1) % storage.count
        } else {
            storage[(head + count) % storage.count] = next
            count += 1
        }
        window = nil
        var firstIndex = 0
        while firstIndex < count - 1, next.sampledAt - sample(firstIndex).sampledAt > 5 {
            firstIndex += 1
        }
        let first = sample(firstIndex)
        let duration = next.sampledAt - first.sampledAt
        guard duration >= 1 else { return }
        var maxBytes: Int32 = 0, maxMilliseconds: Int32 = 0
        var maxRTT = 0.0
        for index in firstIndex..<count {
            let item = sample(index)
            maxBytes = max(maxBytes, item.senderBufferedBytes)
            maxMilliseconds = max(maxMilliseconds, item.senderBufferMilliseconds)
            maxRTT = max(maxRTT, item.rttMilliseconds)
        }
        // Normalize both weights and gauges before summing; even a finite RTT near
        // Double.max must not overflow a value*time intermediate. Endpoint maxima
        // include the last sample, but that sample has no extrapolated time weight.
        var bytes = 0.0, milliseconds = 0.0, rtt = 0.0
        for index in firstIndex..<(count - 1) {
            let item = sample(index)
            let weight = (sample(index + 1).sampledAt - item.sampledAt) / duration
            if maxBytes > 0 { bytes += (Double(item.senderBufferedBytes) / Double(maxBytes)) * weight }
            if maxMilliseconds > 0 { milliseconds += (Double(item.senderBufferMilliseconds) / Double(maxMilliseconds)) * weight }
            if maxRTT > 0 { rtt += (item.rttMilliseconds / maxRTT) * weight }
        }
        let sentDelta = next.sentBytes - first.sentBytes
        let retransmittedDelta = next.retransmittedBytes - first.retransmittedBytes
        let droppedDelta = next.droppedPackets - first.droppedPackets
        let meanBytes = min(1.0, bytes) * Double(maxBytes)
        let meanMilliseconds = min(1.0, milliseconds) * Double(maxMilliseconds)
        let meanRTT = min(1.0, rtt) * maxRTT
        window = PublishingTransportWindow(publishingGeneration: next.publishingGeneration, start: first.sampledAt,
                       end: next.sampledAt, sampleCount: count - firstIndex,
                       sentBytes: sentDelta,
                       retransmittedBytes: retransmittedDelta,
                       droppedPackets: droppedDelta,
                       meanBufferedBytes: meanBytes,
                       meanBufferMilliseconds: meanMilliseconds,
                       meanRTTMilliseconds: meanRTT,
                       maximumBufferedBytes: maxBytes, maximumBufferMilliseconds: maxMilliseconds,
                       maximumRTTMilliseconds: maxRTT)
    }
}
