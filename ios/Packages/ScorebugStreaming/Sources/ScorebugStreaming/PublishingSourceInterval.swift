import CoreMedia
import ScorebugMedia
import SRTHaishinKit

/// Historical counts on (previous decoded endpoint, current decoded endpoint].
/// Callers must independently establish consecutive receiver windows, matching
/// publication/worker/profile scope and freshness. This is not viewer delivery.
public struct PublishingSourceInterval: Sendable {
    public let scope: VideoFrameObservationScope
    public let publishingGeneration: UInt64
    public let relayOriginPTS: Int64
    public let sourceStartExclusive: CMTime
    public let sourceEndInclusive: CMTime
    public let captureBoundaryStartTime: Double
    public let captureBoundaryEndTime: Double
    public let capturedFrames: Int
    public let encodedFrames: Int
    public let decodedFrames: Int
    public var captureNotEncodedFrames: Int { capturedFrames - encodedFrames }
    public var encodedNotDecodedFrames: Int { encodedFrames - decodedFrames }
    public let leadingMissingEncodedFrames: Int

    public static func match(history: VideoSourceHistorySnapshot, clock: PublishingTransportClock,
                             relayOriginPTS: Int64, previousDecodedPTS: Int64,
                             firstDecodedPTS: Int64, lastDecodedPTS: Int64,
                             decodedFrames: Int64) -> Self? {
        guard history.invalidity == nil, (0..<PublishingTransportClock.wireModulus).contains(relayOriginPTS),
              previousDecodedPTS < firstDecodedPTS, firstDecodedPTS <= lastDecodedPTS,
              decodedFrames > 0, (decodedFrames == 1) == (firstDecodedPTS == lastDecodedPTS),
              let projector = TransportClock(origin: clock.sourceOrigin) else { return nil }
        let span = lastDecodedPTS.subtractingReportingOverflow(previousDecodedPTS)
        let leadingSpan = firstDecodedPTS.subtractingReportingOverflow(previousDecodedPTS)
        guard !span.overflow, !leadingSpan.overflow, span.partialValue < PublishingTransportClock.wireModulus / 2,
              let capture = project(history.capture, using: projector),
              let encoded = project(history.encoded, using: projector) else { return nil }

        // A history shorter than half a wrap with strictly increasing projected
        // ticks has at most one occurrence of each modular coordinate.
        func encodedIndex(_ decodedPTS: Int64) -> Int? {
            encoded.firstIndex { modulo($0.ticks - relayOriginPTS) == modulo(decodedPTS) }
        }
        guard let previous = encodedIndex(previousDecodedPTS),
              let first = encodedIndex(firstDecodedPTS), let last = encodedIndex(lastDecodedPTS),
              previous < first, first <= last,
              encoded[last].ticks - encoded[previous].ticks == span.partialValue,
              encoded[first].ticks - encoded[previous].ticks == leadingSpan.partialValue,
              decodedFrames <= Int64(last - first + 1),
              let captureStart = capture.firstIndex(where: { $0.ticks == encoded[previous].ticks }),
              let captureEnd = capture.firstIndex(where: { $0.ticks == encoded[last].ticks }),
              captureStart < captureEnd else { return nil }

        // Counts alone cannot prove provenance: every encoded source timestamp,
        // including the exclusive anchor, must actually occur in capture history.
        var captureIndex = captureStart
        for index in previous...last {
            let pts = encoded[index].frame.sourcePTS
            while captureIndex <= captureEnd, CMTimeCompare(capture[captureIndex].frame.sourcePTS, pts) < 0 {
                captureIndex += 1
            }
            guard captureIndex <= captureEnd,
                  CMTimeCompare(capture[captureIndex].frame.sourcePTS, pts) == 0 else { return nil }
        }
        return Self(scope: history.scope, publishingGeneration: clock.publishingGeneration,
            relayOriginPTS: relayOriginPTS, sourceStartExclusive: encoded[previous].frame.sourcePTS,
            sourceEndInclusive: encoded[last].frame.sourcePTS,
            captureBoundaryStartTime: capture[captureStart].frame.observedAt,
            captureBoundaryEndTime: capture[captureEnd].frame.observedAt,
            capturedFrames: captureEnd - captureStart, encodedFrames: last - previous,
            decodedFrames: Int(decodedFrames), leadingMissingEncodedFrames: first - previous - 1)
    }

    private struct Projected {
        let frame: VideoSourceFrame
        let ticks: Int64
    }

    private static func project(_ frames: [VideoSourceFrame], using clock: TransportClock) -> [Projected]? {
        var result: [Projected] = []
        result.reserveCapacity(frames.count)
        for frame in frames {
            // Capture/encoder callbacks may precede the muxer's selected A/V
            // origin. They cannot be part of a projected delivered interval.
            if CMTimeCompare(frame.sourcePTS, clock.origin) < 0 { continue }
            guard let ticks = clock.presentationTimestamp(for: frame.sourcePTS),
                  result.last.map({ ticks > $0.ticks }) ?? true else { return nil }
            if let first = result.first, ticks - first.ticks >= PublishingTransportClock.wireModulus / 2 { return nil }
            result.append(Projected(frame: frame, ticks: ticks))
        }
        return result.isEmpty ? nil : result
    }

    private static func modulo(_ ticks: Int64) -> Int64 {
        let remainder = ticks % PublishingTransportClock.wireModulus
        return remainder < 0 ? remainder + PublishingTransportClock.wireModulus : remainder
    }
}
