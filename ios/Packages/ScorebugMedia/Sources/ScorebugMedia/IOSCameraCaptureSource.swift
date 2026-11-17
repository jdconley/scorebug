#if os(iOS) && !targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import Foundation

public enum CameraCaptureError: Error, Sendable {
    case permissionDenied, invalidState, unavailableDevice, unsupportedFormat, unsupportedOutput
    case startupFailed, missingClock
}

/// One explicit camera recording. Construction neither requests permission nor
/// activates hardware. The owner must call stop() even after partial preparation.
/// Only preview-layer attachment may use previewSession; configuration is private.
public final class IOSCameraCaptureSource: CaptureSource, Sendable {
    private let core: CameraCaptureCore
    public init(profile: ArchiveProfile = ArchiveProfile()) { core = CameraCaptureCore(profile: profile) }
    deinit { core.requestStop() }
    public var previewSession: AVCaptureSession { core.session }
    public var diagnosticSnapshot: CaptureSourceDiagnostics { core.diagnosticSnapshot }

    public func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        guard await AVCaptureDevice.requestAccess(for: .video),
              await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CameraCaptureError.permissionDenied
        }
        return try await core.prepare(callbacks: callbacks)
    }
    public func start() async throws { try await core.start() }
    public func stop() async { await core.stop() }
    /// Rotates recorded and streamed frames to match how the phone is held: 0 (landscape right,
    /// the sensor's own orientation) or 180 (landscape left). Frames stay landscape either way, so
    /// it can change mid-recording without changing the encoded dimensions.
    public func setVideoRotationAngle(_ angle: CGFloat) { core.setVideoRotationAngle(angle) }
}

/// Session configuration belongs to controlQueue. Delegate delivery belongs to
/// sampleQueue. The short gate lock joins notification callbacks with teardown;
/// it never waits for encoding, networking, or MainActor work.
private final class CameraCaptureCore: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let profile: ArchiveProfile
    init(profile: ArchiveProfile) { self.profile = profile; super.init() }
    let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "live.scorebug.camera.control", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "live.scorebug.camera.samples", qos: .userInitiated)
    private let video = AVCaptureVideoDataOutput()
    private let audio = AVCaptureAudioDataOutput()
    private enum State { case idle, prepared, delivering, stopped }
    private var state = State.idle
    private var observers: [NSObjectProtocol] = []
    private var audioActive = false
    private let gate = NSLock()
    private var callbacks: CaptureSourceCallbacks?
    private var deliveryEnabled = false
    private var origin = CMTime.invalid
    private var diagnostics = CaptureSourceDiagnostics()
    private var pressureObservation: NSKeyValueObservation?
    private var rotationAngle: CGFloat = 0
    var diagnosticSnapshot: CaptureSourceDiagnostics { gate.withLock { diagnostics } }

    func setVideoRotationAngle(_ angle: CGFloat) {
        guard angle == 0 || angle == 180 else { return }
        controlQueue.async {
            self.rotationAngle = angle
            guard let connection = self.video.connection(with: .video), connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }

    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async {
                do {
                    guard self.state == .idle else { throw CameraCaptureError.invalidState }
                    self.gate.withLock { self.callbacks = callbacks }
                    try self.configure()
                    self.installObservers()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw CameraCaptureError.startupFailed }
                    guard let clock = self.session.synchronizationClock else { throw CameraCaptureError.missingClock }
                    let timestamp = CMClockGetTime(clock)
                    guard timestamp.isNumeric, timestamp.seconds.isFinite else { throw CameraCaptureError.missingClock }
                    self.gate.withLock { self.origin = timestamp }
                    self.state = .prepared
                    continuation.resume(returning: timestamp)
                } catch {
                    self.stopOnControlQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                guard self.state == .prepared, self.session.isRunning else {
                    continuation.resume(throwing: CameraCaptureError.invalidState); return
                }
                self.gate.withLock { self.deliveryEnabled = true }
                self.state = .delivering
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { self.stopOnControlQueue(); continuation.resume() }
        }
    }
    func requestStop() { controlQueue.async { self.stopOnControlQueue() } }

    private func configure() throws {
        try profile.validate()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .videoRecording)
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setActive(true)
        audioActive = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.usesApplicationAudioSession = true
        session.automaticallyConfiguresApplicationAudioSession = false
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.sessionPreset = .inputPriority
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CameraCaptureError.unavailableDevice }
        guard let format = camera.formats.first(where: {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == profile.width && size.height == profile.height &&
                $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(profile.framesPerSecond) && $0.maxFrameRate >= Double(profile.framesPerSecond) }
        }) else { throw CameraCaptureError.unsupportedFormat }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
            throw CameraCaptureError.unavailableDevice
        }
        session.addInput(cameraInput)
        session.addInput(microphoneInput)
        try camera.lockForConfiguration()
        camera.activeFormat = format
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(profile.framesPerSecond))
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(profile.framesPerSecond))
        camera.automaticallyAdjustsVideoHDREnabled = false
        if format.isVideoHDRSupported { camera.isVideoHDREnabled = false }
        camera.unlockForConfiguration()
        pressureObservation = camera.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] camera, _ in
            guard let self else { return }
            let level = camera.systemPressureState.level
            let name = level == .nominal ? "nominal" : level == .fair ? "fair" :
                level == .serious ? "serious" : level == .critical ? "critical" :
                level == .shutdown ? "shutdown" : "unknown"
            self.gate.withLock { self.diagnostics.cameraPressureLevel = name }
        }
        guard video.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              session.canAddOutput(video), session.canAddOutput(audio) else { throw CameraCaptureError.unsupportedOutput }
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        video.alwaysDiscardsLateVideoFrames = true
        // The core strongly owns its outputs and is retained by the source for
        // the complete session. Both delegates use one ordered callback queue.
        video.setSampleBufferDelegate(self, queue: sampleQueue)
        audio.setSampleBufferDelegate(self, queue: sampleQueue)
        session.addOutput(video)
        session.addOutput(audio)
        guard let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(0) else {
            throw CameraCaptureError.unsupportedOutput
        }
        // Sensor landscape (0) or upside down (180) at the selected capture dimensions.
        connection.videoRotationAngle = connection.isVideoRotationAngleSupported(rotationAngle) ? rotationAngle : 0
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.report(.failed)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.report(.interrupted)
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                self?.report(.interrupted)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] _ in
            self?.report(.interrupted, onlyWhileDelivering: true)
        })
    }

    private func report(_ event: CaptureSourceEvent, onlyWhileDelivering: Bool = false) {
        gate.withLock {
            guard !onlyWhileDelivering || deliveryEnabled else { return }
            callbacks?.event(event)
        }
    }

    private func stopOnControlQueue() {
        guard state != .stopped else { return }
        // Disable delivery under the same lock as callback invocation, then join
        // the delegate queue. No callback can remain active after stop returns.
        gate.withLock { deliveryEnabled = false }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        pressureObservation = nil
        video.setSampleBufferDelegate(nil, queue: nil)
        audio.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        sampleQueue.sync {}
        if audioActive {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { report(.failed) }
        }
        gate.withLock { callbacks = nil }
        audioActive = false
        state = .stopped
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        gate.withLock {
            guard deliveryEnabled, let callbacks else { return }
            let timestamp = sampleBuffer.presentationTimeStamp
            guard timestamp.isNumeric, timestamp.seconds.isFinite else { callbacks.event(.failed); return }
            // Capture was warmed before the recording origin was chosen. Queued
            // pre-record samples are deliberately outside this recording.
            guard timestamp >= origin else { return }
            do {
                let sample = try CapturedMediaSample(sampleBuffer: sampleBuffer, kind: output === video ? .video : .audio)
                diagnostics.delivered(video: output === video)
                callbacks.sample(sample)
            } catch { callbacks.event(.failed) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        gate.withLock {
            guard deliveryEnabled, let callbacks else { return }
            let timestamp = sampleBuffer.presentationTimeStamp
            if timestamp.isNumeric, timestamp < origin { return }
            let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
            let classified: CaptureVideoDropReason
            if reason == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) { classified = .frameWasLate }
            else if reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) { classified = .outOfBuffers }
            else if reason == (kCMSampleBufferDroppedFrameReason_Discontinuity as String) { classified = .discontinuity }
            else { classified = .unknown }
            diagnostics.dropped(classified)
            callbacks.event(.droppedSample)
        }
    }
}
#endif
