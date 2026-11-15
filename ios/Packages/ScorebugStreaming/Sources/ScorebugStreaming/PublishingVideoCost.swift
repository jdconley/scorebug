import CoreMedia
import Foundation
import ScorebugMedia

/// Historical pre-mux H.264 payload cost. No audio, mux overhead or spare capacity
/// is included, and a different scene/profile cannot reuse this as candidate cost.
public struct PublishingVideoCostInterval: Sendable {
    public let sequence: UInt64
    public let publishingGeneration: UInt64
    public let encoderSessionID: UUID
    public let configuration: VideoEncodingConfiguration?
    public let width: Int32, height: Int32
    public let sourceStartExclusive: CMTime, sourceEndInclusive: CMTime
    public let submissionStart: Double, submissionEnd: Double, observedAt: Double
    public let frames: Int, maximumFrameBytes: Int
    public let payloadBytes: UInt64
    public let maximumLatency: Double
    public let maximumSourceGap: Double
    public var sourceDuration: Double { (sourceEndInclusive - sourceStartExclusive).seconds }
    public var submissionDuration: Double { submissionEnd - submissionStart }
    public var payloadBitsPerSecond: Double { Double(payloadBytes) * 8 / min(sourceDuration, submissionDuration) }
    public var usable: Bool {
        sourceDuration >= 2 && sourceDuration <= 2.25 && submissionDuration > 0 && submissionDuration <= 2.25 &&
        Double(frames) / max(sourceDuration, submissionDuration) >= 24 &&
        maximumSourceGap <= 0.25 && maximumLatency <= 1.5
    }
}
public struct PublishingVideoCostSnapshot: Sendable {
    public let scope: VideoFrameObservationScope
    public let intervals: [PublishingVideoCostInterval]
    public let invalidReason: String?
    public let isClosed: Bool
}

/// Synchronous scalar callback join. Memory is bounded by 64 unmatched records per
/// stream and eight completed windows. Never retains a sample buffer or performs I/O.
public final class PublishingVideoCostOwner: @unchecked Sendable {
    private struct Key: Hashable {
        let value: Int64, scale: Int64
        init?(_ pts: CMTime) {
            guard pts.isNumeric, pts.timescale > 0, pts.epoch == 0, pts.value >= 0, pts.seconds <= 1e12 else { return nil }
            var a = pts.value, b = Int64(pts.timescale)
            while b != 0 { let r = a % b; a = b; b = r }
            value = pts.value / a; scale = Int64(pts.timescale) / a
        }
    }
    private struct Encoded { let pts: CMTime, session: UUID, configuration: VideoEncodingConfiguration?, submitted: Double, completed: Double }
    private struct Compressed { let generation: UInt64, pts: CMTime, width: Int32, height: Int32, bytes: Int, at: Double }
    private struct Joined {
        let encoded: Encoded, compressed: Compressed
        func sameConfiguration(as other: Self) -> Bool {
            encoded.session == other.encoded.session && encoded.configuration == other.encoded.configuration &&
            compressed.generation == other.compressed.generation && compressed.width == other.compressed.width && compressed.height == other.compressed.height
        }
    }
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private var encoded: [Key: Encoded] = [:], compressed: [Key: Compressed] = [:]
    private var order: [Key] = []
    private var lastCompressed: Compressed?, previous: Joined?, anchor: Joined?
    private var frames = 0, maximumFrame = 0
    private var bytes: UInt64 = 0, sequence: UInt64 = 0
    private var latency = 0.0, gap = 0.0
    private var intervals: [PublishingVideoCostInterval] = []
    private var invalid: String?, closed = false
    public init(scope: VideoFrameObservationScope) { self.scope = scope }
    public var snapshot: PublishingVideoCostSnapshot {
        lock.withLock { .init(scope: scope, intervals: intervals, invalidReason: invalid, isClosed: closed) }
    }
    public func fresh(at now: Double = ProcessInfo.processInfo.systemUptime) -> PublishingVideoCostInterval? {
        lock.withLock {
            guard !closed, invalid == nil, let last = intervals.last, last.usable,
                  let previous, let anchor, previous.sameConfiguration(as: anchor),
                  CMTimeCompare(last.sourceEndInclusive, anchor.compressed.pts) == 0,
                  last.encoderSessionID == previous.encoded.session, last.configuration == previous.encoded.configuration,
                  last.publishingGeneration == previous.compressed.generation,
                  last.width == previous.compressed.width, last.height == previous.compressed.height,
                  now.isFinite, now >= last.observedAt, now - last.observedAt <= 1.5 else { return nil }
            guard encoded.values.allSatisfy({ $0.session == last.encoderSessionID && $0.configuration == last.configuration }),
                  compressed.values.allSatisfy({ $0.generation == last.publishingGeneration && $0.width == last.width && $0.height == last.height }) else { return nil }
            return last
        }
    }
    public func close() {
        lock.withLock {
            guard !closed else { return }
            if !encoded.isEmpty || !compressed.isEmpty { reject("incompleteJoin") }
            closed = true
        }
    }
    private func reject(_ reason: String) {
        invalid = invalid ?? reason; encoded.removeAll(); compressed.removeAll(); order.removeAll()
    }
    private func resetWindow(_ value: Joined) {
        anchor = value; frames = 0; bytes = 0; maximumFrame = 0; latency = 0; gap = 0
    }
    func observeEncoding(_ frame: SRTPublisher.EncoderFrame) {
        let configuration = frame.configuration.flatMap {
            VideoEncodingConfiguration(id: $0.id, encoderSessionID: $0.encoderSessionID, bitRate: $0.bitRate)
        }
        recordEncoding(sourcePTS: frame.sourcePTS, outputPTS: frame.outputPTS, session: frame.encoderSessionID,
                       configuration: configuration, submittedAt: frame.submittedAt, completedAt: frame.completedAt)
    }
    func observeCompressed(_ frame: SRTPublisher.CompressedVideoFrame) {
        recordCompressed(generation: frame.publishingGeneration, pts: frame.sourcePTS, width: frame.width,
            height: frame.height, valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264,
            bytes: frame.byteCount, dequeuedAt: frame.dequeuedAt)
    }
    func recordEncoding(sourcePTS: CMTime, outputPTS: CMTime, session: UUID,
                        configuration: VideoEncodingConfiguration?, submittedAt: Double, completedAt: Double) {
        lock.withLock {
            guard !closed, invalid == nil else { return }
            guard let key = Key(sourcePTS), Key(outputPTS) == key,
                  [submittedAt, completedAt].allSatisfy({ $0.isFinite && (0...1e12).contains($0) }),
                  completedAt >= submittedAt, configuration.map({ $0.encoderSessionID == session }) ?? true,
                  encoded[key] == nil, encoded.count < 64,
                  previous.map({ CMTimeCompare(sourcePTS, $0.compressed.pts) > 0 }) ?? true else { reject("invalidEncoding"); return }
            encoded[key] = .init(pts: sourcePTS, session: session, configuration: configuration, submitted: submittedAt, completed: completedAt)
            drain()
        }
    }
    func recordCompressed(generation: UInt64, pts: CMTime, width: Int32, height: Int32, valid: Bool, bytes: Int, dequeuedAt: Double) {
        lock.withLock {
            guard !closed, invalid == nil else { return }
            guard let key = Key(pts), valid, generation > 0, width > 0, height > 0,
                  (1...16 * 1024 * 1024).contains(bytes), dequeuedAt.isFinite, (0...1e12).contains(dequeuedAt),
                  compressed[key] == nil, compressed.count < 64,
                  lastCompressed.map({ CMTimeCompare(pts, $0.pts) > 0 && dequeuedAt >= $0.at && generation == $0.generation }) ?? true else { reject("invalidCompressed"); return }
            let value = Compressed(generation: generation, pts: pts, width: width, height: height, bytes: bytes, at: dequeuedAt)
            compressed[key] = value; order.append(key); lastCompressed = value
            drain()
        }
    }
    private func drain() {
        while let key = order.first, let e = encoded[key], let c = compressed[key] {
            encoded.removeValue(forKey: key); compressed.removeValue(forKey: key); order.removeFirst()
            guard !encoded.values.contains(where: { CMTimeCompare($0.pts, c.pts) < 0 }) else { reject("orphanedEncoding"); return }
            let value = Joined(encoded: e, compressed: c)
            guard c.at >= e.completed,
                  previous.map({ e.submitted > $0.encoded.submitted && CMTimeCompare(c.pts, $0.compressed.pts) > 0 }) ?? true else { reject("invalidJoin"); return }
            let old = previous; previous = value
            guard let start = anchor, value.sameConfiguration(as: start), let old else { resetWindow(value); continue }
            guard frames < 256, bytes + UInt64(c.bytes) <= 64 * 1024 * 1024 else { reject("windowLimit"); return }
            frames += 1; bytes += UInt64(c.bytes); maximumFrame = max(maximumFrame, c.bytes)
            latency = max(latency, c.at - e.submitted); gap = max(gap, (c.pts - old.compressed.pts).seconds)
            let duration = c.pts - start.compressed.pts
            guard duration >= CMTime(value: 2, timescale: 1) else { continue }
            sequence += 1
            intervals.append(.init(sequence: sequence, publishingGeneration: c.generation, encoderSessionID: e.session,
                configuration: e.configuration, width: c.width, height: c.height,
                sourceStartExclusive: start.compressed.pts, sourceEndInclusive: c.pts,
                submissionStart: start.encoded.submitted, submissionEnd: e.submitted, observedAt: c.at,
                frames: frames, maximumFrameBytes: maximumFrame, payloadBytes: bytes,
                maximumLatency: latency, maximumSourceGap: gap))
            if intervals.count > 8 { intervals.removeFirst() }
            resetWindow(value)
        }
    }
}
