import Foundation

/// Internal lifecycle boundary; the stream owner supplies pause/deadline/join.
enum VideoEncoderReplacementError: Error, Equatable {
    case notEncoding, busy, notDrained, obsolete
    case drainFailed(status: Int32)
}

/// Captures one native session without transferring mutable VideoCodec state.
/// Native completion runs once, outside the state lock. The stream owner must
/// execute it off its actor and join it even after terminal invalidation.
final class VideoEncoderReplacement: @unchecked Sendable {
    let settings: VideoCodecSettings
    let revision: UUID
    let failure: PublishingFailureLatch
    private let session: any VTSessionConvertible
    private let lock = NSLock()
    private var started = false
    private var result: Int32?
    init(settings: VideoCodecSettings, revision: UUID, session: any VTSessionConvertible,
         failure: PublishingFailureLatch) {
        self.settings = settings; self.revision = revision; self.session = session; self.failure = failure
    }
    var drainResult: Int32? { lock.withLock { result } }
    func drain() {
        let begin = lock.withLock { if started { return false }; started = true; return true }
        guard begin else { return }
        let status = session.completeFrames()
        lock.withLock { result = status }
    }
}
