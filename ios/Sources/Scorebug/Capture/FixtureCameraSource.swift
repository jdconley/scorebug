#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia

/// Deterministic Simulator input. One retained pump emits immutable video/PCM in
/// real time; stop cancels and joins that pump. Production chooses the device source.
final class FixtureCameraSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let profile: ArchiveProfile
    private let failAfterFrames: Int?
    private let motionFlag: String?
    private var motion: FixtureMotionPattern?
    private let origin = CMTime(value: 7_395, timescale: 60) // 123.25 s, not wall time.
    private var callbacks: CaptureSourceCallbacks?
    private var pump: Task<Void, Never>?
    private var used = false
    private var archivePressureDiagnostics: ArchivePressureDiagnostics?

    /// One owner may attach before prepare, without changing the capture protocol.
    @discardableResult func attachArchivePressureDiagnostics(_ owner: ArchivePressureDiagnostics) -> Bool {
        lock.withLock {
            guard !used, archivePressureDiagnostics == nil, owner.attachProducer() else { return false }
            archivePressureDiagnostics = owner
            return true
        }
    }
    init(profile: ArchiveProfile = .init(), failAfterFrames: Int? = nil, motionFlag: String? = nil) {
        self.profile = profile; self.failAfterFrames = failAfterFrames; self.motionFlag = motionFlag
    }
    deinit { pump?.cancel() }
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        try lock.withLock {
            guard !used else { throw FixtureError.state }
            try profile.validate()
            guard profile.framesPerSecond == 30, profile.audioSampleRate == 48_000,
                  profile.audioChannels == 1 else { throw FixtureError.format }
            if let pattern = try FixtureMotionPattern.selection(motionFlag) {
                motion = try FixtureMotionPattern(profile: profile, pattern: pattern)
            }
            used = true
            self.callbacks = callbacks
            return origin
        }
    }
    func start() async throws {
        try lock.withLock {
            guard pump == nil, let callbacks else { throw FixtureError.state }
            let profile = profile, origin = origin, failAfterFrames = failAfterFrames
            let diagnostics = archivePressureDiagnostics
            let motion = motion
            pump = Task.detached {
                let began = ContinuousClock.now
                do {
                    var frame = 0
                    while true {
                        try Task.checkCancellation()
                        let deadline = began + .seconds(Double(frame) / 30)
                        try await ContinuousClock().sleep(until: deadline)
                        if let failAfterFrames, frame >= failAfterFrames { callbacks.event(.interrupted); return }
                        diagnostics?.beginFrame(index: Int64(frame), deadline: deadline)
                        let samples = try autoreleasepool {
                            (try Self.video(frame: frame, profile: profile, origin: origin, motion: motion),
                             try Self.audio(frame: frame, origin: origin))
                        }
                        diagnostics?.generationFinished()
                        diagnostics?.callbacksStarted()
                        callbacks.sample(try CapturedMediaSample(sampleBuffer: samples.0, kind: .video))
                        callbacks.sample(try CapturedMediaSample(sampleBuffer: samples.1, kind: .audio))
                        diagnostics?.callbacksFinished()
                        frame += 1
                    }
                } catch is CancellationError {} catch { callbacks.event(.failed) }
            }
        }
    }
    func stop() async {
        let pending = lock.withLock { callbacks = nil; return (task: pump, prepared: used) }
        pending.task?.cancel()
        await pending.task?.value
        if pending.prepared {
            // Published samples own independent pixel buffers, so releasing the
            // prepared textures after the joined pump cannot alter their pixels.
            lock.withLock { motion = nil; pump = nil }
        }
    }
    private enum FixtureError: Error { case state, format, buffer }
    private static func video(frame: Int, profile: ArchiveProfile, origin: CMTime, motion: FixtureMotionPattern?) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, profile.width, profile.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
            let pixel else { throw FixtureError.buffer }
        CVPixelBufferLockBaseAddress(pixel, [])
        do {
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            for plane in 0..<2 {
                memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane == 0 ? 32 : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
            }
            if let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
                let bandWidth = max(1, profile.width / 16)
                for bit in 0..<16 {
                    let level = (frame >> bit) & 1 == 1 ? 220 : 70
                    for row in 0..<profile.height / 3 {
                        memset(luma.advanced(by: row * stride + bit * bandWidth), Int32(level), bandWidth)
                    }
                }
                if motion == nil {
                    let position = (frame * 8) % max(1, profile.width - 40)
                    for row in (profile.height / 2)..<min(profile.height, profile.height / 2 + 40) {
                        memset(luma.advanced(by: row * stride + position), 230, 40)
                    }
                }
            }
            try motion?.copyMiddle(into: pixel, frame: frame)
        }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescriptionOut: &format) == noErr, let format else { throw FixtureError.buffer }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: origin + CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { throw FixtureError.buffer }
        return sample
    }
    /// Short, frequency-coded bursts align the decoded audio with the visible frame barcode.
    static func markerPCM(at time: Double) -> Int16 {
        guard time.truncatingRemainder(dividingBy: 2) < 0.2 else { return 0 }
        let frequency = 1000.0 + 20.0 * floor(time / 2.0)
        return Int16(16383.5 * sin(2.0 * Double.pi * frequency * time))
    }
    private static func audio(frame: Int, origin: CMTime) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { throw FixtureError.buffer }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw FixtureError.buffer }
        let pcm: [Int16] = (0..<count).map { sample in
            let time = Double(frame * count + sample) / 48_000
            return markerPCM(at: time)
        }
        let status = pcm.withUnsafeBytes { data in
            CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw FixtureError.buffer }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: origin + CMTime(value: Int64(frame * count), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { throw FixtureError.buffer }
        return sample
    }
}
#endif
