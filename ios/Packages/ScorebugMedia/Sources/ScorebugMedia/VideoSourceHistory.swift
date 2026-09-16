import CoreMedia
import Foundation

public struct VideoSourceFrame: Sendable {
    public let sourcePTS: CMTime
    public let observedAt: Double
}

public enum VideoSourceHistoryInvalidity: Sendable, Equatable {
    case sourcePTS, sourceOrder, monotonicClock, overflow
}

public struct VideoSourceHistorySnapshot: Sendable {
    public let scope: VideoFrameObservationScope
    public let capture: [VideoSourceFrame]
    public let encoded: [VideoSourceFrame]
    public let omittedCaptureFrames: UInt64
    public let omittedEncodedFrames: UInt64
    public let invalidity: VideoSourceHistoryInvalidity?
    public let isClosed: Bool
}

/// Bounded scalar history for later source-interval matching. Callers serialize
/// access. No media is retained; appending updates one ring slot without shifting.
/// Snapshot creation copies chronological entries on the requesting path.
/// Invalid evidence quarantines this entire history; start a new owner to reset.
public struct VideoSourceHistory: Sendable {
    public enum ConfigurationError: Error { case invalidCapacity }
    private let scope: VideoFrameObservationScope
    private var capture: Ring
    private var encoded: Ring
    private var lastTime: Double?
    private var invalidity: VideoSourceHistoryInvalidity?
    private var closed = false

    public init(scope: VideoFrameObservationScope, capacity: Int = 2048) throws {
        guard (1...8192).contains(capacity) else { throw ConfigurationError.invalidCapacity }
        self.scope = scope
        capture = Ring(capacity: capacity)
        encoded = Ring(capacity: capacity)
    }
    public var snapshot: VideoSourceHistorySnapshot {
        .init(scope: scope, capture: capture.frames, encoded: encoded.frames,
              omittedCaptureFrames: capture.omitted, omittedEncodedFrames: encoded.omitted,
              invalidity: invalidity, isClosed: closed)
    }
    @discardableResult
    public mutating func observe(_ stage: VideoFrameObservationStage, sourcePTS: CMTime, at time: Double) -> Bool {
        guard !closed, invalidity == nil else { return false }
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else {
            invalidity = .monotonicClock; return false
        }
        lastTime = time
        guard sourcePTS.isNumeric, sourcePTS.timescale > 0, sourcePTS.epoch == 0 else {
            invalidity = .sourcePTS; return false
        }
        let previous = stage == .captureVideo ? capture.lastPTS : encoded.lastPTS
        guard previous.map({ CMTimeCompare(sourcePTS, $0) > 0 }) ?? true else {
            invalidity = .sourceOrder; return false
        }
        let frame = VideoSourceFrame(sourcePTS: sourcePTS, observedAt: time)
        switch stage {
        case .captureVideo: if !capture.append(frame) { invalidity = .overflow }
        case .encodedVideo: if !encoded.append(frame) { invalidity = .overflow }
        }
        return invalidity == nil
    }

    public mutating func close() { closed = true }

    private struct Ring: Sendable {
        private var storage: [VideoSourceFrame?]
        private var next = 0
        private var count = 0
        private(set) var omitted: UInt64 = 0
        private(set) var lastPTS: CMTime?
        init(capacity: Int) { storage = Array(repeating: nil, count: capacity) }
        mutating func append(_ frame: VideoSourceFrame) -> Bool {
            if count == storage.count {
                guard omitted < .max else { return false }
                omitted += 1
            } else { count += 1 }
            storage[next] = frame
            next = (next + 1) % storage.count
            lastPTS = frame.sourcePTS
            return true
        }
        var frames: [VideoSourceFrame] {
            let start = count == storage.count ? next : 0
            return (0..<count).map { storage[(start + $0) % storage.count]! }
        }
    }
}
