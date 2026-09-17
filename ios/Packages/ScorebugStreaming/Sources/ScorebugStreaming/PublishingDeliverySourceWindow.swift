import CoreMedia
import ScorebugMedia
import SRTHaishinKit

/// Complete captured-source expectations for a half-open one/two-second window.
/// This proves local history/configuration coverage and coordinate arithmetic only.
/// The caller must bind clock, receipt, relay origin and an actual decoded anchor
/// to the same currently owned publication, and independently validate freshness.
public struct PublishingDeliverySourceWindow: Sendable {
    public struct Frame: Sendable {
        public let sourcePTS: CMTime
        public let decodedPTS: Int64
        public let capturedAt: Double
        public let wasEncoded: Bool
    }
    public let scope: VideoFrameObservationScope
    public let publishingGeneration: UInt64
    public let configuration: VideoEncodingConfiguration
    public let windowStart: Double
    public let windowEnd: Double
    public let frames: [Frame]
    public let encodedFrames: Int

    public static func match(history: VideoSourceHistorySnapshot, clock: PublishingTransportClock,
                             receipt: PublishingBitRateChange, acknowledgedAt: Double,
                             windowStart: Double, windowEnd: Double, relayOriginPTS: Int64,
                             anchorDecodedPTS: Int64) -> Self? {
        let maximum: Int64 = 9_007_199_254_740_991
        let halfWrap = PublishingTransportClock.wireModulus / 2
        func finite(_ value: Double) -> Bool { value.isFinite && (0...1e12).contains(value) }
        guard history.invalidity == nil, !history.isClosed,
              receipt.publishingGeneration == clock.publishingGeneration,
              finite(acknowledgedAt), acknowledgedAt >= receipt.acceptedAt,
              finite(windowStart), finite(windowEnd), windowStart >= acknowledgedAt,
              [1.0, 2.0].contains(windowEnd - windowStart),
              (0..<PublishingTransportClock.wireModulus).contains(relayOriginPTS),
              (-maximum...maximum).contains(anchorDecodedPTS),
              let projector = TransportClock(origin: clock.sourceOrigin),
              let left = history.capture.lastIndex(where: { $0.observedAt < windowStart }),
              let right = history.capture.firstIndex(where: { $0.observedAt >= windowEnd }),
              right > left + 1, right - left - 1 <= 240 else { return nil }
        let captures = history.capture[(left + 1)..<right]
        // Strict local observation times are required by deadline arithmetic.
        // A retained frame before start and at/after end proves no ring retirement
        // or unfinished capture tail can hide frames from this interval.
        var previousTime = history.capture[left].observedAt
        for frame in history.capture[(left + 1)...right] {
            guard finite(frame.observedAt), frame.observedAt > previousTime else { return nil }
            previousTime = frame.observedAt
        }
        let firstSource = captures.first!.sourcePTS
        let rightSource = history.capture[right].sourcePTS
        guard receipt.lastSubmittedSourcePTS.map({ CMTimeCompare(firstSource, $0) > 0 }) ?? true,
              let firstEncoded = history.encoded.first,
              CMTimeCompare(firstEncoded.sourcePTS, firstSource) < 0,
              let completionBoundary = history.encoded.first(where: { CMTimeCompare($0.sourcePTS, rightSource) >= 0 }),
              history.capture.contains(where: { CMTimeCompare($0.sourcePTS, completionBoundary.sourcePTS) == 0 })
        else { return nil }

        // Every completion inside the window must refer to a captured source and
        // carry the accepted native configuration. Completion brackets ensure the
        // retained encoder tail cannot hide pending or evicted metadata. The first
        // completion beyond the window must also have captured provenance. Captures
        // without a completion remain expectations, rather than disappearing.
        var encodedIndices = Set<Int>()
        var captureIndex = captures.startIndex
        for frame in history.encoded where CMTimeCompare(frame.sourcePTS, firstSource) >= 0
            && CMTimeCompare(frame.sourcePTS, rightSource) < 0 {
            while captureIndex < captures.endIndex,
                  CMTimeCompare(captures[captureIndex].sourcePTS, frame.sourcePTS) < 0 { captureIndex += 1 }
            guard captureIndex < captures.endIndex,
                  CMTimeCompare(captures[captureIndex].sourcePTS, frame.sourcePTS) == 0,
                  let encoding = frame.encoding, encoding.configuration == receipt.configuration,
                  encoding.submittedAt >= captures[captureIndex].observedAt else { return nil }
            encodedIndices.insert(captureIndex)
        }

        // An actual decoded coordinate identifies the unwrapped epoch. Do not
        // guess it from modulo alone: the decoder may expose negative PTS or
        // unwrap across the 33-bit transport boundary. Ambiguous anchors fail.
        var anchor: (source: CMTime, ticks: Int64)?
        var firstTicks: Int64?, previousTicks: Int64?
        for frame in history.encoded {
            if CMTimeCompare(frame.sourcePTS, clock.sourceOrigin) < 0 { continue }
            guard let ticks = projector.presentationTimestamp(for: frame.sourcePTS),
                  previousTicks.map({ ticks > $0 }) ?? true else { return nil }
            if let firstTicks, ticks - firstTicks >= halfWrap { return nil }
            firstTicks = firstTicks ?? ticks; previousTicks = ticks
            if modulo(ticks - relayOriginPTS) == modulo(anchorDecodedPTS) {
                guard anchor == nil else { return nil }
                anchor = (frame.sourcePTS, ticks)
            }
        }
        guard let anchor, history.capture.contains(where: { CMTimeCompare($0.sourcePTS, anchor.source) == 0 }) else { return nil }
        var frames: [Frame] = []
        var previousProjected: Int64?
        for index in captures.indices {
            let capture = captures[index]
            guard let ticks = projector.presentationTimestamp(for: capture.sourcePTS) else { return nil }
            let difference = ticks.subtractingReportingOverflow(anchor.ticks)
            guard !difference.overflow, difference.partialValue > -halfWrap,
                  difference.partialValue < halfWrap else { return nil }
            let decoded = anchorDecodedPTS.addingReportingOverflow(difference.partialValue)
            guard !decoded.overflow, (-maximum...maximum).contains(decoded.partialValue),
                  previousProjected.map({ decoded.partialValue > $0 }) ?? true else { return nil }
            frames.append(.init(sourcePTS: capture.sourcePTS, decodedPTS: decoded.partialValue, capturedAt: capture.observedAt,
                wasEncoded: encodedIndices.contains(index)))
            previousProjected = decoded.partialValue
        }
        return .init(scope: history.scope, publishingGeneration: clock.publishingGeneration,
            configuration: receipt.configuration, windowStart: windowStart, windowEnd: windowEnd,
            frames: frames, encodedFrames: encodedIndices.count)
    }

    private static func modulo(_ ticks: Int64) -> Int64 {
        let remainder = ticks % PublishingTransportClock.wireModulus
        return remainder < 0 ? remainder + PublishingTransportClock.wireModulus : remainder
    }
}
