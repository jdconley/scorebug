#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// One publishing attempt owns constant-size pre-mux format evidence. No sample
/// buffers are retained. Persistence runs only after the adapter joins its stop.
final class NativePublishingFormatFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private let profile: PublishingVideoProfile
    private var frames = 0
    private var invalid = false
    private var generation: UInt64?
    private var width: Int32?
    private var height: Int32?
    private var first: CMTime?
    private var last: CMTime?
    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile) {
        self.scope = scope; self.profile = profile
    }
    func observe(_ frame: SRTPublisher.CompressedVideoFrame) {
        record(generation: frame.publishingGeneration, pts: frame.sourcePTS, width: frame.width,
               height: frame.height, valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264)
    }
    func record(generation: UInt64, pts: CMTime, width: Int32, height: Int32, valid: Bool) {
        lock.withLock {
            guard frames < 25_000 else { invalid = true; return }
            frames += 1
            guard valid, generation > 0, pts.isNumeric, pts.timescale > 0,
                  width > 0, height > 0 else { invalid = true; return }
            if let previous = self.generation, previous != generation { invalid = true }
            if let previous = self.width, previous != width { invalid = true }
            if let previous = self.height, previous != height { invalid = true }
            if let previous = last, previous.epoch != pts.epoch || CMTimeCompare(pts, previous) <= 0 { invalid = true }
            if self.generation == nil { self.generation = generation; self.width = width; self.height = height; first = pts }
            last = pts
        }
    }
    func data() throws -> Data {
        let value: [String: Any] = lock.withLock {
            ["formatVersion": 1, "isClosed": true, "profile": profile.rawValue,
             "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                       "broadcastGeneration": scope.broadcastGeneration,
                       "publishingAttemptID": scope.publishingAttemptID.uuidString,
                       "appliedProfileRevision": String(scope.appliedProfileRevision)],
             "frames": frames, "invalid": invalid,
             "publishingGeneration": generation.map { String($0) } as Any? ?? NSNull(),
             "width": width as Any? ?? NSNull(), "height": height as Any? ?? NSNull(),
             "firstSourcePTS": first.map(Self.time) as Any? ?? NSNull(),
             "lastSourcePTS": last.map(Self.time) as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func persist() {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data().write(to: directory.appendingPathComponent("native-publishing-format.json"), options: .atomic)
        } catch { /* Missing evidence fails qualification; diagnostics never fail recording. */ }
    }
    private static func time(_ value: CMTime) -> [String: Any] {
        ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
    }
}
#endif
