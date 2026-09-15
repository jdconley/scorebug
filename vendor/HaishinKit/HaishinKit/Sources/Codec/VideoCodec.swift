import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    static let frameInterval: Double = 0.0

    private let encoderCompletionObserver: VideoEncoderCompletionObserver?

    private let sessionFactory: ((VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)?
    init(encoderCompletionObserver: VideoEncoderCompletionObserver? = nil,
         sessionFactory: ((VTSessionMode, VideoCodec) throws -> any VTSessionConvertible)? = nil) {
        self.encoderCompletionObserver = encoderCompletionObserver
        self.sessionFactory = sessionFactory
    }

    func requestSessionInvalidation() { invalidation.invalidate() }

    func setVerifiedBitRate(_ bitRate: Int) throws -> VideoCodecSettings {
        guard isRunning, failure.error == nil, sessionMode == .compression, let session else {
            throw VideoBitRateUpdateError.notEncoding
        }
        let observed = invalidation.snapshot
        guard !observed.pending else { throw VideoBitRateUpdateError.sessionInvalidated }
        let updated: VideoCodecSettings
        do { updated = try VerifiedVideoBitRate.apply(bitRate, to: settings, session: session) }
        catch let error as VideoBitRateUpdateError {
            // A failed attempted native mutation is not a successful rollback.
            switch error {
            case .writeFailed(_, let status), .readFailed(_, let status):
                failure.fail(.codecFailed(status: status))
            case .readbackMismatch:
                failure.fail(.codecFailed(status: -1))
            default: break // Preflight rejection made no native call.
            }
            throw error
        }
        guard failure.error == nil else { throw VideoBitRateUpdateError.notEncoding }
        guard invalidation.isCurrent(observed.revision) else {
            failure.fail(.codecFailed(status: -1))
            throw VideoBitRateUpdateError.sessionInvalidated
        }
        // This is accepted configuration at this point, not a frame boundary or
        // achieved output rate. Do not repeat settings' legacy unchecked apply.
        storedSettings = updated
        return updated
    }


    private var storedSettings: VideoCodecSettings = .default
    var settings: VideoCodecSettings {
        get { storedSettings }
        set {
            let previous = storedSettings
            storedSettings = newValue
            if newValue.invalidateSession(previous) { requestSessionInvalidation() }
            else { newValue.apply(self, rhs: previous) }
        }
    }
    var passthrough = true
    var failure = PublishingFailureLatch()
    var outputLimits = PublishingQueue<CMSampleBuffer>.Limits(count: 8, bytesPerItem: 2 * 1024 * 1024)
    var outputStream: AsyncStream<CMSampleBuffer> {
        continuation?.finish()
        let queue = PublishingQueue<CMSampleBuffer>(boundary: "video codec", limits: outputLimits, failure: failure)
        continuation = queue
        return queue.stream
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: PublishingQueue<CMSampleBuffer>?
    private let invalidation = VideoCodecInvalidation()
    private var sessionMode: VTSessionMode?
    private var presentationTimeStamp: CMTime?
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            requestSessionInvalidation()
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, failure.error == nil else {
            return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            let observed = invalidation.snapshot
            if observed.pending {
                let mode: VTSessionMode = sampleBuffer.formatDescription?.isCompressed == true ? .decompression : .compression
                session = try sessionFactory?(mode, self) ?? mode.makeSession(self)
                sessionMode = mode
                invalidation.installed(observed.revision)
            }
            guard invalidation.isCurrent(observed.revision) else { return }
            guard let session, let continuation else {
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: encoderCompletionObserver)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    try session.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: encoderCompletionObserver)
                    presentationTimeStamp = sampleBuffer.presentationTimeStamp
                }
            }
        } catch {
            failure.fail(.codecFailed(status: (error as? VTSessionError)?.status ?? -1))
            logger.warn(error)
        }
    }

    /// Capture after raw input drains. The caller runs this off its stream actor
    /// so callbacks can be consumed concurrently within the existing queue bound.
    /// Only terminal invalidation may overlap the captured native session.
    func makeCompletion() -> @Sendable () -> Void {
        let completion = VideoCompletion(session: session, output: continuation, failure: failure)
        return { completion.run() }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        // A stream has no previous frame until its first accepted input. Zero is a
        // valid first PTS, including after restart and with a frame limiter enabled.
        guard let previousTimeStamp = self.presentationTimeStamp else {
            return true
        }
        guard previousTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - previousTimeStamp.seconds
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        requestSessionInvalidation()
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            requestSessionInvalidation()
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        sessionMode = nil
        requestSessionInvalidation()
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = nil
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}

/// Native VideoToolbox sessions support callback completion and invalidation;
/// this immutable owner transfers no mutable VideoCodec state off its actor.
private struct VideoCompletion: @unchecked Sendable {
    let session: (any VTSessionConvertible)?
    let output: PublishingQueue<CMSampleBuffer>?
    let failure: PublishingFailureLatch
    func run() {
        if let session {
            let status = session.completeFrames()
            if status != noErr { failure.fail(.codecFailed(status: status)) }
        }
        output?.finish()
    }
}
