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
    // Preserve ~16 seconds at the app's 100ms cadence, including aged source-window brackets.
    private var storage = [PublishingTransportStatistics?](repeating: nil, count: 160)
    private var head = 0
    private var count = 0
    private(set) var window: PublishingTransportWindow?
    var samples: [PublishingTransportStatistics] { (0..<count).map { sample($0) } }

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

/// Sampled gauges over requested bounds, with counters kept on enclosing collections.
public struct PublishingTransportInterval: Equatable, Sendable {
    public let publishingGeneration: UInt64
    public let start: Double
    public let end: Double
    public let enclosingStart: Double
    public let enclosingEnd: Double
    public let sampleCount: Int
    public let enclosingSentBytes: UInt64
    public let enclosingRetransmittedBytes: UInt64
    public let enclosingDroppedPackets: Int32
    public let meanBufferedBytes: Double
    public let meanBufferMilliseconds: Double
    public let meanRTTMilliseconds: Double
    public let enclosingMaximumBufferedBytes: Int32
    public let enclosingMaximumBufferMilliseconds: Int32
    public let enclosingMaximumRTTMilliseconds: Double
}
public extension PublishingTransportStatisticsSnapshot {
    /// No extrapolation or counter interpolation. Caller independently establishes
    /// attempt/configuration association, freshness and policy pressure thresholds.
    func interval(from start: Double, to end: Double) -> PublishingTransportInterval? {
        guard !isQuarantined, start.isFinite, end.isFinite, start >= 0, end > start, end <= 1e12,
              let left = samples.lastIndex(where: { $0.sampledAt <= start }),
              let right = samples.firstIndex(where: { $0.sampledAt >= end }), left < right else { return nil }
        let points = samples[left...right], first = samples[left], last = samples[right]
        let maxBytes = points.map(\.senderBufferedBytes).max()!, maxMilliseconds = points.map(\.senderBufferMilliseconds).max()!
        let maxRTT = points.map(\.rttMilliseconds).max()!
        var bytes = 0.0, milliseconds = 0.0, rtt = 0.0
        for i in left..<right {
            let weight = max(0, min(end, samples[i + 1].sampledAt) - max(start, samples[i].sampledAt)) / (end - start)
            if maxBytes > 0 { bytes += Double(samples[i].senderBufferedBytes) / Double(maxBytes) * weight }
            if maxMilliseconds > 0 { milliseconds += Double(samples[i].senderBufferMilliseconds) / Double(maxMilliseconds) * weight }
            if maxRTT > 0 { rtt += samples[i].rttMilliseconds / maxRTT * weight }
        }
        let meanBytes = min(1.0, bytes) * Double(maxBytes)
        let meanMilliseconds = min(1.0, milliseconds) * Double(maxMilliseconds)
        let meanRTT = min(1.0, rtt) * maxRTT
        let sent = last.sentBytes - first.sentBytes
        let retransmitted = last.retransmittedBytes - first.retransmittedBytes
        let dropped = last.droppedPackets - first.droppedPackets
        return PublishingTransportInterval(publishingGeneration: first.publishingGeneration, start: start, end: end,
            enclosingStart: first.sampledAt, enclosingEnd: last.sampledAt, sampleCount: right - left + 1,
            enclosingSentBytes: sent,
            enclosingRetransmittedBytes: retransmitted,
            enclosingDroppedPackets: dropped,
            meanBufferedBytes: meanBytes,
            meanBufferMilliseconds: meanMilliseconds,
            meanRTTMilliseconds: meanRTT, enclosingMaximumBufferedBytes: maxBytes,
            enclosingMaximumBufferMilliseconds: maxMilliseconds, enclosingMaximumRTTMilliseconds: maxRTT)
    }
}
