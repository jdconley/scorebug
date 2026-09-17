import CoreMedia
import Foundation
import ScorebugMedia

/// First-frame scalar evidence owned by one terminal publisher. No media, tasks,
/// timers or history buffers are retained. Later frames never rewrite startup.
final class PublishingVideoStartupOwner: @unchecked Sendable {
    struct Snapshot: Sendable {
        let receipt: PublishingVideoStartup?
        let invalidReason: String?
        let isClosed: Bool
    }
    private struct Encoding {
        let pts: CMTime, session: UUID, submitted: Double, completed: Double
    }
    private struct Compressed {
        let pts: CMTime, generation: UInt64, width: Int, height: Int, at: Double
    }
    private let lock = NSLock()
    private let profile: PublishingVideoProfile
    private var encoding: Encoding?
    private var compressed: Compressed?
    private var receipt: PublishingVideoStartup?
    private var invalid: String?
    private var closed = false
    init(profile: PublishingVideoProfile) { self.profile = profile }
    var snapshot: Snapshot { lock.withLock { .init(receipt: receipt, invalidReason: invalid, isClosed: closed) } }
    func recordEncoding(sourcePTS: CMTime, outputPTS: CMTime, encoderSessionID: UUID,
                        submittedAt: Double, completedAt: Double) {
        lock.withLock {
            guard !closed, invalid == nil, receipt == nil, encoding == nil else { return }
            guard Self.validPTS(sourcePTS), Self.validPTS(outputPTS), CMTimeCompare(sourcePTS, outputPTS) == 0,
                  Self.validTime(submittedAt), Self.validTime(completedAt), submittedAt <= completedAt
            else { reject("invalidFirstEncoding"); return }
            encoding = .init(pts: sourcePTS, session: encoderSessionID, submitted: submittedAt, completed: completedAt)
            join()
        }
    }
    func recordCompressed(sourcePTS: CMTime, publishingGeneration: UInt64, width: Int,
                          height: Int, valid: Bool, isSync: Bool, dequeuedAt: Double) {
        lock.withLock {
            guard !closed, invalid == nil, receipt == nil, compressed == nil else { return }
            guard Self.validPTS(sourcePTS), publishingGeneration > 0, valid, isSync,
                  width == profile.width, height == profile.height, Self.validTime(dequeuedAt)
            else { reject("invalidFirstCompressed"); return }
            compressed = .init(pts: sourcePTS, generation: publishingGeneration, width: width, height: height, at: dequeuedAt)
            join()
        }
    }
    func close() {
        lock.withLock { closed = true; encoding = nil; compressed = nil }
    }
    private func join() {
        guard let encoding, let compressed else { return }
        guard CMTimeCompare(encoding.pts, compressed.pts) == 0,
              let value = PublishingVideoStartup(profile: profile, width: compressed.width, height: compressed.height,
                publishingGeneration: compressed.generation, encoderSessionID: encoding.session,
                firstSourcePTS: encoding.pts, submittedAt: encoding.submitted, completedAt: encoding.completed,
                observedAt: compressed.at) else { reject("invalidFirstFrameJoin"); return }
        receipt = value; self.encoding = nil; self.compressed = nil
    }
    private func reject(_ reason: String) { invalid = reason; encoding = nil; compressed = nil }
    private static func validTime(_ time: Double) -> Bool { time.isFinite && (0...1e12).contains(time) }
    private static func validPTS(_ pts: CMTime) -> Bool {
        pts.isNumeric && pts.timescale > 0 && pts.epoch == 0 && pts.value >= 0 && pts.seconds <= 1e12
    }
}
