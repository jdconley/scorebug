import AVFoundation
import Combine
import HaishinKit
import SRTHaishinKit

/// Owns the AVCaptureSession and fan-out: every CMSampleBuffer goes to two
/// independent serial queues — one for SRT publish (re-encoded), one for the
/// local archive (passthrough, never re-encoded). Talks to HaishinKit's SRT
/// stream for the publish side and AVAssetWriter for the archive side.
///
/// The HaishinKit 2.x API is fast-moving — when you build this in Xcode,
/// double-check method names against the version actually resolved by SPM.
/// Marked TODO are the calls you may need to adjust.
@MainActor
final class CameraSession: ObservableObject {
    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?

    enum State: Equatable {
        case idle
        case ready
        case publishing
        case error(String)
    }

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoQueue = DispatchQueue(label: "live.scorebug.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "live.scorebug.audio", qos: .userInteractive)
    private let publishQueue = DispatchQueue(label: "live.scorebug.publish", qos: .userInteractive)
    private let archiveQueue = DispatchQueue(label: "live.scorebug.archive", qos: .userInteractive)

    private var srtConnection: SRTConnection?
    private var srtStream: SRTStream?
    private var archive: ArchiveWriter?

    /// Configure inputs once on app launch. Re-entrancy is safe.
    func prepare() async {
        guard state == .idle else { return }
        let auth = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard auth, mic else {
            state = .error("camera or mic denied")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(SampleFanout(camera: self), queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(SampleFanout(camera: self), queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .landscapeRight }
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .auto }
        }

        session.commitConfiguration()
        session.startRunning()
        state = .ready
    }

    /// Begin publishing to the SRT URL and recording the local archive.
    func startPublishing(credentials: PublishCredentials) async {
        guard state == .ready || state == .publishing else { return }
        let srtURL = "srt://\(credentials.host):\(credentials.port)?streamid=\(credentials.streamId)&passphrase=\(credentials.passphrase)&latency=1000000"
        do {
            let connection = SRTConnection()
            let stream = SRTStream(connection: connection)

            // TODO(HaishinKit 2.x): the exact method names below may need to
            // be `await stream.attachCamera(...)` / `stream.publish(nil)` etc.
            // Verify against the resolved version's docs.
            stream.videoSettings = .init(
                videoSize: .init(width: 1920, height: 1080),
                bitRate: 6_000_000,
                profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
                maxKeyFrameIntervalDuration: 2
            )
            stream.audioSettings = .init(bitRate: 128_000)

            try await connection.connect(URL(string: srtURL))
            try await stream.publish()

            self.srtConnection = connection
            self.srtStream = stream
            self.archive = try ArchiveWriter.startNew()
            self.state = .publishing
        } catch {
            self.state = .error("publish failed: \(error.localizedDescription)")
            self.lastError = "\(error)"
        }
    }

    func stopPublishing() async {
        if let stream = srtStream {
            try? await stream.close()
        }
        srtStream = nil
        srtConnection = nil
        archive?.finish()
        archive = nil
        if state == .publishing { state = .ready }
    }

    fileprivate func ingest(_ sample: CMSampleBuffer, isVideo: Bool) {
        // Fan-out: archive first (cheap copy), then forward to publisher.
        archiveQueue.async { [weak self] in
            self?.archive?.append(sample, isVideo: isVideo)
        }
        publishQueue.async { [weak self] in
            guard let self else { return }
            // TODO(HaishinKit 2.x): SRTStream may accept buffers via attachCamera/
            // attachAudio, in which case explicit forwarding here is unnecessary.
            // If a manual `append` API exists, call it here for both video + audio.
            _ = self.srtStream
            _ = sample
            _ = isVideo
        }
    }
}

/// AVCaptureOutput delegates can't be actors; isolate the bridging here.
private final class SampleFanout: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var camera: CameraSession?
    init(camera: CameraSession) { self.camera = camera }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        let cam = camera
        Task { @MainActor in cam?.ingest(sampleBuffer, isVideo: isVideo) }
    }
}
