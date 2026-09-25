import AVFoundation
import Foundation

/// An object that provides a stream ingest feature.
package final class OutgoingStream {
    package private(set) var isRunning = false
    private var inputFinished = false
    package private(set) var rawVideoFramesDropped: UInt64 = 0

    /// The asynchronous sequence for audio output.
    package var audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)> {
        return audioCodec.outputStream
    }

    /// Specifies the audio compression properties.
    package var audioSettings: AudioCodecSettings {
        get {
            audioCodec.settings
        }
        set {
            audioCodec.settings = newValue
        }
    }

    /// The audio input format.
    package private(set) var audioInputFormat: CMFormatDescription?

    /// Explicit pacing experiment: retain at most sixteen compressed frames,
    /// still at most 2 MiB each. Overflow remains a terminal publishing failure.
    package func enablePacedVideoOutput() -> Bool {
        guard !isRunning else { return false }
        videoCodec.outputLimits = .init(count: 16, bytesPerItem: 2 * 1024 * 1024)
        return true
    }

    /// The asynchronous sequence for video output.
    package var videoOutputStream: AsyncStream<CMSampleBuffer> {
        return videoCodec.outputStream
    }

    /// Specifies the video compression properties.
    package var videoSettings: VideoCodecSettings {
        get {
            videoCodec.settings
        }
        set {
            videoCodec.settings = newValue
        }
    }

    package func setVerifiedVideoBitRate(_ bitRate: Int, expecting expected: VideoBitRateExpectation? = nil,
                                          continuing continuation: VideoReplacementContinuation? = nil) throws -> VideoCodecSettings {
        guard isRunning, !inputFinished else { throw VideoBitRateUpdateError.notEncoding }
        return try videoCodec.setVerifiedBitRate(bitRate, expecting: expected, continuing: continuation)
    }

    package func prepareVideoReplacement(_ settings: VideoCodecSettings, expecting expected: VideoBitRateExpectation? = nil) throws -> VideoEncoderReplacement {
        guard isRunning, !inputFinished else { throw VideoEncoderReplacementError.notEncoding }
        return try videoCodec.prepareReplacement(settings, expecting: expected)
    }
    package func commitVideoReplacement(_ operation: VideoEncoderReplacement) throws {
        try videoCodec.commitReplacement(operation)
    }
    package var videoReplacementContinuation: VideoReplacementContinuation? { videoCodec.replacementContinuation }
    package func validateVideoAdmission(_ expected: VideoReplacementContinuation) throws { try videoCodec.validateAdmission(expected) }
    package var lastVideoSubmission: (sessionID: UUID, sourcePTS: CMTime)? { videoCodec.lastSubmission }

    package var lastVideoBitRateChange: VideoBitRateChange? { videoCodec.lastBitRateChange }

    /// Specifies the video buffering count.
    package var videoInputBufferCounts = -1

    /// The asynchronous sequence for video input buffer.
    package var videoInputStream: AsyncStream<CMSampleBuffer> {
        if 0 < videoInputBufferCounts {
            return AsyncStream(CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(videoInputBufferCounts)) { continuation in
                self.videoInputContinuation = continuation
            }
        } else {
            return AsyncStream { continuation in
                self.videoInputContinuation = continuation
            }
        }
    }

    /// The video input format.
    package private(set) var videoInputFormat: CMFormatDescription?

    private var audioCodec = AudioCodec()
    private let videoCodec: VideoCodec
    private var videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    package func setPublishingFailure(_ failure: PublishingFailureLatch) {
        videoCodec.failure = failure
        audioCodec.failure = failure
    }

    /// Create a new instance.
    package init(encoderCompletionObserver: VideoEncoderCompletionObserver? = nil,
                 encoderConfigurationObserver: VideoEncoderConfigurationObserver? = nil,
                 encoderSubmissionObserver: VideoEncoderSubmissionObserver? = nil) {
        videoCodec = VideoCodec(encoderCompletionObserver: encoderCompletionObserver,
                                encoderConfigurationObserver: encoderConfigurationObserver,
                                encoderSubmissionObserver: encoderSubmissionObserver)
    }

    init(videoCodec: VideoCodec) { self.videoCodec = videoCodec }

    /// Appends a sample buffer for publish.
    package func append(_ sampleBuffer: CMSampleBuffer) {
        guard !inputFinished else { return }
        switch sampleBuffer.formatDescription?.mediaType {
        case .audio:
            audioInputFormat = sampleBuffer.formatDescription
            audioCodec.append(sampleBuffer)
        case .video:
            videoInputFormat = sampleBuffer.formatDescription
            if case .dropped = videoInputContinuation?.yield(sampleBuffer) { rawVideoFramesDropped &+= 1 }
        default:
            break
        }
    }

    /// Appends a sample buffer for publish.
    package func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard !inputFinished else { return }
        audioInputFormat = audioBuffer.format.formatDescription
        audioCodec.append(audioBuffer, when: when)
    }

    /// Ends ingress, preserving already queued raw video and complete AAC packets.
    /// Raw-video consumer must drain before makeVideoCompletion is invoked.
    package func finishInput() {
        inputFinished = true
        videoInputContinuation = nil
        audioCodec.stopRunning()
    }

    package func makeVideoCompletion() -> @Sendable () -> Void { videoCodec.makeCompletion() }

    package func prepareVideoSubmission(_ sample: CMSampleBuffer) -> VideoSubmission? {
        videoCodec.prepareSubmission(sample)
    }
    @discardableResult package func commitVideoSubmission(_ operation: VideoSubmission, succeeded: Bool) -> Bool {
        videoCodec.commitSubmission(operation, succeeded: succeeded)
    }

    /// Appends a video buffer.
    package func append(video sampleBuffer: CMSampleBuffer) {
        videoCodec.append(sampleBuffer)
    }
}

extension OutgoingStream: Runner {
    // MARK: Runner
    package func startRunning() {
        guard !isRunning else {
            return
        }
        inputFinished = false
        rawVideoFramesDropped = 0
        videoCodec.startRunning()
        audioCodec.startRunning()
        isRunning = true
    }

    package func stopRunning() {
        inputFinished = true
        guard isRunning else {
            return
        }
        isRunning = false
        videoCodec.stopRunning()
        audioCodec.stopRunning()
        videoInputContinuation = nil
    }
}
