@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a one-way channel over a SRTConnection.
public actor SRTStream {
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// A latched transport muxer failure. Cleared when the stream is closed/reset.
    public var muxerError: MuxerError? { writer.error }

    public enum MuxerError: Swift.Error, Equatable, Sendable {
        case payloadByteLimitExceeded
        case outputByteLimitExceeded
        case outputQueueLimitExceeded
        case invalidTimestamp
        case invalidPayload
        case startupPacketLimitExceeded
        case startupByteLimitExceeded
        case startupTimeLimitExceeded
        case incompleteStartup
    }

    /// First terminal publishing failure; retained through close and reset by publish.
    public var publishingError: PublishingError? { failure.error ?? writer.failure.error }
    private var failure = PublishingFailureLatch()
    private var generation: UInt64 = 0
    private var videoInputIsRaw = false
    /// Identity for an active publication, not proof that its encoder is ready.
    public var publishingGeneration: UInt64? {
        readyState == .publishing && finishingGeneration == nil && publishingError == nil && muxerError == nil
            ? generation : nil
    }
    public struct TransportClockSnapshot: Equatable, Sendable {
        public let publishingGeneration: UInt64
        public let clock: TransportClock
    }
    /// Muxer-selected mapping only; never a claim of transport receipt or frame loss.
    public var transportClockSnapshot: TransportClockSnapshot? {
        guard let generation = publishingGeneration, let clock = writer.transportClock else { return nil }
        return .init(publishingGeneration: generation, clock: clock)
    }

    /// Point-in-time native configuration acknowledgment. It is not a source-frame
    /// boundary, achieved output rate, or authorization to relabel queued frames.
    public func setVerifiedVideoBitRate(_ bitRate: Int, publishingGeneration expected: UInt64) throws -> VideoCodecSettings {
        try setVerifiedVideoBitRateWithReceipt(bitRate, publishingGeneration: expected).change.settings
    }
    public struct VideoBitRateReceipt: Sendable {
        public let publishingGeneration: UInt64
        public let change: VideoBitRateChange
    }
    public func setVerifiedVideoBitRateWithReceipt(_ bitRate: Int, publishingGeneration expected: UInt64) throws -> VideoBitRateReceipt {
        try Task.checkCancellation()
        guard publishingGeneration == expected, videoInputIsRaw else { throw VideoBitRateUpdateError.notEncoding }
        _ = try outgoing.setVerifiedVideoBitRate(bitRate)
        guard let change = outgoing.lastVideoBitRateChange else { throw VideoBitRateUpdateError.sessionInvalidated }
        return .init(publishingGeneration: expected, change: change)
    }
    private struct PublishingTasks {
        let video, audio, input, transport, errors: Task<Void, Never>
        var all: [Task<Void, Never>] { [video, audio, input, transport, errors] }
    }
    private var publishingTasks: PublishingTasks?
    private var finishingGeneration: UInt64?
    private var finishTask: Task<Void, Never>?

    /// The expected medias for transport stream.
    public var expectedMedias: Set<AVMediaType> {
        writer.expectedMedias
    }

    @Published public private(set) var readyState: StreamReadyState = .idle
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max
    package var outputs: [any StreamOutput] = []
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private lazy var writer = TSWriter()
    private lazy var reader = TSReader()
    package lazy var incoming = IncomingStream(self)
    package let outgoing: OutgoingStream
    private weak var connection: SRTConnection?

    /// The error domain codes.
    public enum Error: Swift.Error {
        // An unsupported codec.
        case unsupportedCodec
    }

    /// Creates a new stream object.
    /// - Parameter encoderCompletionObserver: Immutable, synchronous native encoder
    ///   notification for this stream, including final drain. Compressed passthrough
    ///   does not notify. The callback must remain bounded and perform no I/O or waits.
    public init(connection: SRTConnection, encoderCompletionObserver: VideoEncoderCompletionObserver? = nil,
                encoderConfigurationObserver: VideoEncoderConfigurationObserver? = nil) {
        outgoing = OutgoingStream(encoderCompletionObserver: encoderCompletionObserver,
                                  encoderConfigurationObserver: encoderConfigurationObserver)
        self.connection = connection
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Sends streaming audio and video from client.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func publish(_ name: String? = "") async {
        guard let connection, let connectionSession = await connection.publishingSession() else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .publishing:
                await close()
            default:
                break
            }
            return
        }
        guard readyState == .idle, finishingGeneration == nil else { return }
        generation &+= 1
        videoInputIsRaw = false
        let session = generation
        failure = PublishingFailureLatch()
        writer.failure = failure
        outgoing.setPublishingFailure(failure)
        // Raw video may skip stale frames before compression; compressed queues fail.
        if outgoing.videoInputBufferCounts <= 0 { outgoing.videoInputBufferCounts = 2 }
        // Install continuations before publishing becomes observable or accepting input.
        let videoOutput = outgoing.videoOutputStream
        let audioOutput = outgoing.audioOutputStream
        let videoInput = outgoing.videoInputStream
        let transportOutput = writer.output
        outgoing.startRunning()
        readyState = .publishing
        if outgoing.videoInputFormat != nil {
            writer.expectedMedias.insert(.video)
        }
        if outgoing.audioInputFormat != nil {
            writer.expectedMedias.insert(.audio)
        }
        if writer.expectedMedias.isEmpty {
            logger.error("Please set expected media.")
        }
        publishingTasks = PublishingTasks(
            video: Task {
                for await buffer in videoOutput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    appendCompressedVideo(buffer)
                }
            },
            audio: Task {
                for await buffer in audioOutput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    appendCompressedAudio(buffer.0, when: buffer.1)
                }
            },
            input: Task {
                for await buffer in videoInput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    outgoing.append(video: buffer)
                }
            },
            transport: Task {
                for await data in transportOutput {
                    guard generation == session, !Task.isCancelled, failure.error == nil else { return }
                    await connection.send(data, generation: connectionSession)
                }
            },
            errors: Task { [failure] in
                for await error in failure.events {
                    guard generation == session, !Task.isCancelled else { return }
                    await connection.failPublishing(error, generation: connectionSession)
                    return
                }
            }
        )
    }

    /// Playback streaming audio and video from server.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func play(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .playing:
                await close()
            default:
                break
            }
            return
        }
        await connection.recv()
        Task {
            await incoming.startRunning()
            for await buffer in reader.output {
                await incoming.append(buffer.1)
            }
        }
        readyState = .playing
    }

    /// Stops ingress and drains accepted publishing media through the codec,
    /// muxer and socket. Success means transport acceptance, not remote delivery.
    /// One owned deadline aborts a stalled drain; all finish callers join the same
    /// operation. Failure is latched in publishingError. close() remains immediate
    /// abort, and publication cannot restart until this operation has joined.
    public func finish(timeout: Duration = .seconds(2)) async {
        if let finishTask { await finishTask.value; return }
        guard readyState == .publishing, let tasks = publishingTasks else { return }
        let session = generation
        finishingGeneration = session
        outgoing.finishInput()
        let pending = Task {
            await drainPublishing(tasks, generation: session, timeout: timeout)
            // Every joining caller must observe a reusable stream at completion;
            // cleanup cannot depend on the original caller being rescheduled.
            if finishingGeneration == session {
                finishTask = nil
                finishingGeneration = nil
            }
        }
        finishTask = pending
        await pending.value
    }

    private func drainPublishing(_ tasks: PublishingTasks, generation session: UInt64, timeout: Duration) async {
        let deadline = Task {
            do { try await Task.sleep(for: max(.zero, timeout)) } catch { return }
            guard generation == session else { return }
            failure.fail(.outputTerminated(boundary: "SRT finish deadline"))
            await close()
        }
        await tasks.input.value
        if generation == session, publishingError == nil {
            let completion = outgoing.makeVideoCompletion()
            // VideoToolbox completion can synchronously wait for callbacks. Let
            // the stream actor consume those callbacks within its bounded queue.
            await Task.detached(priority: .utility) { completion() }.value
        }
        await tasks.video.value
        await tasks.audio.value
        if generation == session, publishingError == nil { writer.finishOutput() }
        else { tasks.transport.cancel() }
        await tasks.transport.value
        if generation == session { await close() }
        deadline.cancel()
        await deadline.value
        await tasks.errors.value
    }

    /// Stops playing or publishing and makes available other uses.
    public func close() async {
        generation &+= 1
        videoInputIsRaw = false
        for task in publishingTasks?.all ?? [] { task.cancel() }
        publishingTasks = nil
        outgoing.stopRunning()
        failure.finish()
        writer.clear()
        reader.clear()
        readyState = .idle
        await incoming.stopRunning()
    }

    /// Sets the expected media.
    ///
    /// This sets whether the stream contains audio only, video only, or both. Normally, this is automatically set through the append method.
    /// If you cannot call the append method before publishing, please use this method to explicitly specify the contents of the stream.
    public func setExpectedMedias(_ expectedMedias: Set<AVMediaType>) {
        writer.expectedMedias = expectedMedias
    }

    func doInput(_ data: Data) {
        _ = reader.read(data)
    }
}

extension SRTStream: _Stream {
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.audioSettings = audioSettings
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.videoSettings = videoSettings
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard publishingError == nil, finishingGeneration == nil else { return }
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                videoInputIsRaw = false
                appendCompressedVideo(sampleBuffer)
            } else {
                videoInputIsRaw = true
                outgoing.append(sampleBuffer)
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        default:
            break
        }
    }

    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard publishingError == nil, finishingGeneration == nil else { return }
        switch audioBuffer {
        case let audioBuffer as AVAudioPCMBuffer:
            outgoing.append(audioBuffer, when: when)
            outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
        case let audioBuffer as AVAudioCompressedBuffer:
            appendCompressedAudio(audioBuffer, when: when)
        default:
            break
        }
    }

    private func appendCompressedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard readyState == .publishing, publishingError == nil else { return }
        writer.videoFormat = sampleBuffer.formatDescription
        writer.append(sampleBuffer)
    }

    private func appendCompressedAudio(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard readyState == .publishing, publishingError == nil,
              let audioBuffer = audioBuffer as? AVAudioCompressedBuffer else { return }
        writer.audioFormat = audioBuffer.format
        writer.append(audioBuffer, when: when)
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension SRTStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}
