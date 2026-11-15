@preconcurrency import AVFoundation
import VideoToolbox
import HaishinKit
import SRTHaishinKit
import ScorebugMedia

/// SRT encoding/transport adapter shared by the app and local qualification tools.
/// Its caller owns bounded raw-media admission and lifecycle serialization.
/// Construct a fresh adapter for every publishing attempt.
public actor SRTPublisher {
    /// Shared by the actual AAC encoder configuration and candidate probe planning.
    public static let audioBitRate = 128_000
    /// Diagnostic values from the existing sequential health reads, not an atomic
    /// observation or proof of receiver delivery. Never includes destination URLs.
    public struct HealthSnapshot: Sendable {
        public let connected: Bool
        public let streamPublishing: Bool
        public let muxerError: SRTStream.MuxerError?
        public let streamError: PublishingError?
        public let transportError: PublishingError?
        public let rawVideoFramesDropped: UInt64?
        public var isPublishing: Bool {
            connected && streamPublishing && muxerError == nil && streamError == nil && transportError == nil
        }
    }
    private let healthObserver: (@Sendable (HealthSnapshot) -> Void)?
    public typealias EncoderSubmission = VideoEncoderSubmission
    public typealias EncoderHardwareSelection = VideoEncoderHardwareSelection
    public typealias TransportSendObservation = SRTStream.TransportSendObservation
    public typealias CompressedAudioFrame = SRTStream.CompressedAudioFrame
    public typealias MuxedPacketFrame = SRTStream.MuxedPacketFrame
    public typealias CompressedVideoFrame = SRTStream.CompressedVideoFrame
    public let videoCost: PublishingVideoCostOwner?
    private nonisolated let startupEvidence: PublishingVideoStartupOwner
    /// Historical evidence remains available after the terminal drain. Session
    /// admission separately requires this same publisher to still be running.
    public nonisolated var videoStartup: PublishingVideoStartup? { startupEvidence.snapshot.receipt }
    private let videoProfile: PublishingVideoProfile
    public struct EncoderConfiguration: Equatable, Sendable {
        public let id: UUID
        public let encoderSessionID: UUID
        public let bitRate: Int
        fileprivate init(_ value: VideoEncoderConfiguration) {
            id = value.id; encoderSessionID = value.encoderSessionID; bitRate = value.bitRate
        }
    }
    public struct EncoderFrame: Sendable {
        public let sourcePTS: CMTime
        public let outputPTS: CMTime
        public let encoderSessionID: UUID
        public let configuration: EncoderConfiguration?
        public let submittedAt: Double
        public let completedAt: Double
        fileprivate init(_ value: VideoEncoderFrame) {
            sourcePTS = value.sourcePTS; outputPTS = value.outputPTS; encoderSessionID = value.encoderSessionID
            configuration = value.configuration.map(EncoderConfiguration.init)
            submittedAt = value.submittedAt; completedAt = value.completedAt
        }
    }
    public typealias BitRateChangeReceipt = PublishingBitRateChange
    public enum PublisherError: Error { case notPublishing, mutationInProgress }
    private let connection = SRTConnection()
    private let stream: SRTStream
    private let stopPolicy: SRTStopPolicy
    private var activeGeneration: UInt64?
    private var stopping = false
    private var configuring = false
    private var probeOperation: Task<PublishingBandwidthProbeSnapshot, Error>?
    private var probeIdentity: PublishingBandwidthProbeSnapshot?
    private var probeOwner: PublishingProbeOperationOwner?
    private var probeRetirement: (owner: PublishingProbeOperationOwner, task: Task<Void, Error>)?
    private var probeRetiring = false
    private var probeCleanupFailed = false
    private var probeRevision: UInt64 = 0
    private let probeContextIssuer = UUID()
    private var probeConfigurationEpoch = UUID()
    private var ownedProbeMode = false
    private var ownedProbeOperation: PublishingBandwidthProbeOperation?
    private var encoderUpdating = false
    private var profileChange: Task<PublishingVideoProfileChange, Error>?
    private var replacementMapping: PublishingVideoReplacementMapping?
    private enum GuardedReceipt: Sendable {
        case bitRate(PublishingBitRateChange)
        case profile(PublishingVideoReplacementMapping)
    }
    private var guardedMutation: (id: UUID, task: Task<GuardedReceipt, Error>)?
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    public private(set) var lastStopOutcome: SRTStopPolicy.Outcome?
    private let probeBudget: PublishingBandwidthProbeSnapshot.Budget
    public init(stopPolicy: SRTStopPolicy = .init(), observations: VideoFrameObservationOwner? = nil,
                encoderConfigurationObserver: (@Sendable (EncoderFrame) -> Void)? = nil,
                videoProfile: PublishingVideoProfile = .hd1080,
                compressedVideoObserver: (@Sendable (CompressedVideoFrame) -> Void)? = nil,
                compressedAudioObserver: (@Sendable (CompressedAudioFrame) -> Void)? = nil,
                muxedPacketObserver: (@Sendable (MuxedPacketFrame) -> Void)? = nil,
                pacesEncodedVideo: Bool = false, allowsBandwidthProbes: Bool = false,
                probeBudget: PublishingBandwidthProbeSnapshot.Budget = .standard,
                videoCost: PublishingVideoCostOwner? = nil,
                healthObserver: (@Sendable (HealthSnapshot) -> Void)? = nil,
                transportSendObserver: (@Sendable (TransportSendObservation) -> Void)? = nil,
                encoderSubmissionObserver: (@Sendable (EncoderSubmission) -> Void)? = nil) {
        self.probeBudget = probeBudget
        self.healthObserver = healthObserver
        let startupEvidence = PublishingVideoStartupOwner(profile: videoProfile)
        self.startupEvidence = startupEvidence
        let cost = videoCost ?? observations.map { PublishingVideoCostOwner(scope: $0.snapshot.scope) }
        self.videoCost = cost
        self.stopPolicy = stopPolicy
        self.videoProfile = videoProfile
        // Immutable ownership prevents late native completions from reaching a
        // later publishing attempt. Observe synchronously without retaining media.
        let configurationObserver: VideoEncoderConfigurationObserver?
        configurationObserver = { frame in
                startupEvidence.recordEncoding(sourcePTS: frame.sourcePTS, outputPTS: frame.outputPTS,
                    encoderSessionID: frame.encoderSessionID, submittedAt: frame.submittedAt, completedAt: frame.completedAt)
                let configuration = frame.configuration.flatMap {
                    VideoEncodingConfiguration(id: $0.id, encoderSessionID: $0.encoderSessionID, bitRate: $0.bitRate)
                }
                // A failed conversion of a present configuration must remain
                // missing evidence, never become an unverified native submission.
                let encoding: VideoEncodingObservation?
                if frame.configuration != nil && configuration == nil { encoding = nil }
                else {
                    encoding = .init(encoderSessionID: frame.encoderSessionID, configuration: configuration,
                                     submittedAt: frame.submittedAt, completedAt: frame.completedAt)
                }
                observations?.observe(.encodedVideo, sourcePTS: frame.sourcePTS, encoding: encoding)
                cost?.observeEncoding(EncoderFrame(frame))
                encoderConfigurationObserver?(EncoderFrame(frame))
            }
        stream = SRTStream(connection: connection, encoderConfigurationObserver: configurationObserver,
                           compressedVideoObserver: { frame in
                               startupEvidence.recordCompressed(sourcePTS: frame.sourcePTS, publishingGeneration: frame.publishingGeneration,
                                   width: Int(frame.width), height: Int(frame.height),
                                   valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264,
                                   isSync: frame.isSync == true, dequeuedAt: frame.dequeuedAt)
                               cost?.observeCompressed(frame)
                               compressedVideoObserver?(frame)
                           }, compressedAudioObserver: compressedAudioObserver,
                           muxedPacketObserver: muxedPacketObserver, pacesEncodedVideo: pacesEncodedVideo,
                           allowsBandwidthProbes: allowsBandwidthProbes, probeBudget: probeBudget, transportSendObserver: transportSendObserver,
                           encoderSubmissionObserver: encoderSubmissionObserver)
    }
    public func configure() async throws {
        try Task.checkCancellation()
        guard !stopping, !configuring, startup == nil, activeGeneration == nil else { throw PublisherError.notPublishing }
        configuring = true
        defer { configuring = false }
        try await stream.setVideoSettings(videoProfile.settings)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: Self.audioBitRate))
        await stream.setExpectedMedias([.video, .audio])
        await stream.setVideoInputBufferCounts(4)
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
    }
    public func start(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !stopping, !configuring, startup == nil, activeGeneration == nil else { throw PublisherError.notPublishing }
        let pending = Task { try await performStart(url) }
        startup = pending
        defer { startup = nil }
        try await withTaskCancellationHandler {
            do {
                try await pending.value
                try Task.checkCancellation()
                guard !stopping else { throw PublisherError.notPublishing }
            } catch {
                // The owned operation has terminated, so joining it cannot self-wait.
                await stop()
                throw error
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }
    private func performStart(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
        try await connection.connect(url)
        try Task.checkCancellation()
        guard !stopping else { throw PublisherError.notPublishing }
        await stream.publish()
        guard await connection.connected, await stream.readyState == .publishing,
              await stream.muxerError == nil, await stream.publishingError == nil,
              await connection.publishingError == nil else {
            throw PublisherError.notPublishing
        }
        guard let generation = await stream.publishingGeneration, !stopping, !Task.isCancelled else {
            throw PublisherError.notPublishing
        }
        activeGeneration = generation
    }
    public func video(_ sample: CMSampleBuffer) async { await stream.append(sample) }
    public func audio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) async { await stream.append(buffer, when: when) }
    public func setBitRate(_ bitRate: Int) async throws {
        _ = try await setBitRateWithReceipt(bitRate)
    }
    public func setBitRateWithReceipt(_ bitRate: Int) async throws -> BitRateChangeReceipt {
        try Task.checkCancellation()
        guard !stopping, let generation = activeGeneration else { throw PublisherError.notPublishing }
        guard !encoderUpdating else { throw PublisherError.mutationInProgress }
        probeConfigurationEpoch = UUID()
        replacementMapping = nil
        encoderUpdating = true
        await invalidateBandwidthProbe()
        defer { encoderUpdating = false }
        let healthy = await isPublishing()
        try Task.checkCancellation()
        guard healthy, !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        let receipt = try await stream.setVerifiedVideoBitRateWithReceipt(bitRate, publishingGeneration: generation)
        guard !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        if Task.isCancelled {
            // Native settings were committed; retire the abandoned live attempt.
            await stop()
            throw CancellationError()
        }
        guard let configuration = VideoEncodingConfiguration(id: receipt.change.configuration.id,
            encoderSessionID: receipt.change.configuration.encoderSessionID, bitRate: receipt.change.configuration.bitRate),
              let change = PublishingBitRateChange(publishingGeneration: receipt.publishingGeneration,
                configuration: configuration, acceptedAt: receipt.change.acceptedAt,
                lastSubmittedSourcePTS: receipt.change.lastSubmittedSourcePTS) else {
            await stop()
            throw PublisherError.notPublishing
        }
        return change
    }
    public func setVideoProfile(_ profile: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        try Task.checkCancellation()
        guard !stopping, let generation = activeGeneration else { throw PublisherError.notPublishing }
        guard !encoderUpdating else { throw PublisherError.mutationInProgress }
        probeConfigurationEpoch = UUID()
        replacementMapping = nil
        encoderUpdating = true
        await invalidateBandwidthProbe()
        guard !stopping, activeGeneration == generation, !Task.isCancelled else { encoderUpdating = false; throw PublisherError.notPublishing }
        let pending = Task { try await performProfileChange(profile, generation: generation) }
        profileChange = pending
        defer { profileChange = nil; encoderUpdating = false }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await pending.value
                guard !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
                try Task.checkCancellation()
                return receipt
            } catch {
                await stop()
                throw error
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }
    private func performProfileChange(_ profile: PublishingVideoProfile, generation: UInt64) async throws -> PublishingVideoProfileChange {
        try Task.checkCancellation()
        let healthy = await isPublishing()
        try Task.checkCancellation()
        guard healthy, !stopping, activeGeneration == generation else { throw PublisherError.notPublishing }
        let native = try await stream.replaceVideoSettings(profile.settings, publishingGeneration: generation)
        let acknowledgedAt = ProcessInfo.processInfo.systemUptime
        let stillHealthy = await isPublishing()
        try Task.checkCancellation()
        guard stillHealthy, !stopping, activeGeneration == generation,
              native.publishingGeneration == generation,
              let receipt = PublishingVideoProfileChange(profile: profile,
                publishingGeneration: native.publishingGeneration,
                previousEncoderSessionID: native.previousEncoderSessionID, encoderSessionID: native.encoderSessionID,
                lastOldSourcePTS: native.lastOldSourcePTS, firstNewSourcePTS: native.firstNewSourcePTS,
                width: Int(native.width), height: Int(native.height), rawVideoFramesDropped: native.rawVideoFramesDropped,
                acknowledgedAt: acknowledgedAt) else { throw PublisherError.notPublishing }
        replacementMapping = .init(native: native, media: receipt)
        return receipt
    }

    /// Read-only, point-in-time native preflight; guarded setters always repeat
    /// this check after suspension and select the same native configuration.
    public func validateVideoMutationExpectation(_ expected: PublishingVideoMutationExpectation) async throws {
        let epoch = probeConfigurationEpoch
        try checkGuardedScope(epoch: epoch, owner: nil)
        let native = try nativeMutationExpectation(expected)
        let healthy = await isPublishing()
        try checkGuardedScope(epoch: epoch, owner: nil)
        guard healthy else { throw PublisherError.notPublishing }
        try await validateNativeMutation(expected, native: native, epoch: epoch, owner: nil)
    }

    private func nativeMutationExpectation(_ expected: PublishingVideoMutationExpectation) throws -> SRTStream.VideoMutationExpectation {
        switch expected {
        case .verified(let selected):
            return .verified(publishingGeneration: selected.publishingGeneration, configuration: selected.nativeExpectation)
        case .replacement(let selected):
            guard let mapping = replacementMapping, mapping.matches(selected) else { throw PublishingVideoMutationAdmissionError.stale }
            return .replacement(mapping.native)
        }
    }

    private func checkGuardedScope(epoch: UUID, owner: UUID?) throws {
        try Task.checkCancellation()
        guard !stopping, activeGeneration != nil else { throw PublisherError.notPublishing }
        guard probeConfigurationEpoch == epoch else { throw PublishingVideoMutationAdmissionError.stale }
        if let owner {
            guard encoderUpdating, guardedMutation?.id == owner else { throw PublishingVideoMutationAdmissionError.stale }
        } else {
            guard !encoderUpdating else { throw PublishingVideoMutationAdmissionError.stale }
        }
    }

    private func validateNativeMutation(_ expected: PublishingVideoMutationExpectation,
        native: SRTStream.VideoMutationExpectation, epoch: UUID, owner: UUID?) async throws {
        if case .verified(let selected) = expected {
            let actual = await stream.verifiedVideoBitRateReceipt
            try checkGuardedScope(epoch: epoch, owner: owner)
            guard let actual, selected.matchesNative(actual) else { throw PublishingVideoMutationAdmissionError.stale }
        }
        do { try await stream.validateVideoMutationExpectation(native) }
        catch {
            try checkGuardedScope(epoch: epoch, owner: owner)
            if error is VideoMutationAdmissionError { throw PublishingVideoMutationAdmissionError.stale }
            throw error
        }
        try checkGuardedScope(epoch: epoch, owner: owner)
    }

    public func setBitRateWithReceipt(_ bitRate: Int, expecting expected: PublishingVideoMutationExpectation) async throws -> BitRateChangeReceipt {
        let result = try await runGuardedMutation(expecting: expected) { native in
            let receipt: SRTStream.VideoBitRateReceipt
            do { receipt = try await self.stream.setVerifiedVideoBitRateWithReceipt(bitRate, expecting: native) }
            catch VideoMutationAdmissionError.stale { throw PublishingVideoMutationAdmissionError.stale }
            guard let configuration = VideoEncodingConfiguration(id: receipt.change.configuration.id,
                    encoderSessionID: receipt.change.configuration.encoderSessionID, bitRate: receipt.change.configuration.bitRate),
                  let change = PublishingBitRateChange(publishingGeneration: receipt.publishingGeneration,
                    configuration: configuration, acceptedAt: receipt.change.acceptedAt,
                    lastSubmittedSourcePTS: receipt.change.lastSubmittedSourcePTS) else { throw PublisherError.notPublishing }
            return .bitRate(change)
        }
        guard case .bitRate(let receipt) = result else { preconditionFailure("Mismatched guarded operation") }
        return receipt
    }

    public func setVideoProfile(_ profile: PublishingVideoProfile, expecting expected: PublishingBitRateChange) async throws -> PublishingVideoProfileChange {
        let result = try await runGuardedMutation(expecting: .verified(expected)) { _ in
            let native: SRTStream.VideoReplacementReceipt
            do {
                native = try await self.stream.replaceVideoSettings(profile.settings,
                    publishingGeneration: expected.publishingGeneration, expecting: expected.nativeExpectation)
            } catch VideoMutationAdmissionError.stale { throw PublishingVideoMutationAdmissionError.stale }
            guard let receipt = PublishingVideoProfileChange(profile: profile,
                publishingGeneration: native.publishingGeneration,
                previousEncoderSessionID: native.previousEncoderSessionID, encoderSessionID: native.encoderSessionID,
                lastOldSourcePTS: native.lastOldSourcePTS, firstNewSourcePTS: native.firstNewSourcePTS,
                width: Int(native.width), height: Int(native.height), rawVideoFramesDropped: native.rawVideoFramesDropped,
                acknowledgedAt: ProcessInfo.processInfo.systemUptime) else { throw PublisherError.notPublishing }
            return .profile(.init(native: native, media: receipt))
        }
        guard case .profile(let mapping) = result else { preconditionFailure("Mismatched guarded operation") }
        return mapping.media
    }

    private func runGuardedMutation(expecting expected: PublishingVideoMutationExpectation,
        operation: @escaping @Sendable (SRTStream.VideoMutationExpectation) async throws -> GuardedReceipt) async throws -> GuardedReceipt {
        let initialEpoch = probeConfigurationEpoch
        try checkGuardedScope(epoch: initialEpoch, owner: nil)
        let native = try nativeMutationExpectation(expected)
        let healthy = await isPublishing()
        try checkGuardedScope(epoch: initialEpoch, owner: nil)
        guard healthy else { throw PublisherError.notPublishing }
        try await validateNativeMutation(expected, native: native, epoch: initialEpoch, owner: nil)
        let id = UUID(), epoch = UUID()
        probeConfigurationEpoch = epoch
        replacementMapping = nil
        encoderUpdating = true
        let pending = Task {
            await self.invalidateBandwidthProbe()
            try self.checkGuardedScope(epoch: epoch, owner: id)
            let healthy = await self.isPublishing()
            try self.checkGuardedScope(epoch: epoch, owner: id)
            guard healthy else { throw PublisherError.notPublishing }
            try await self.validateNativeMutation(expected, native: native, epoch: epoch, owner: id)
            return try await operation(native)
        }
        guardedMutation = (id, pending)
        defer {
            if guardedMutation?.id == id { guardedMutation = nil; encoderUpdating = false }
        }
        return try await withTaskCancellationHandler {
            do {
                let receipt = try await pending.value
                let healthy = await isPublishing()
                // After successful native work every failure is uncertain. Never
                // classify a later scope/health mismatch as a no-effect rejection.
                try Task.checkCancellation()
                guard healthy, !stopping, probeConfigurationEpoch == epoch,
                      guardedMutation?.id == id else { throw PublisherError.notPublishing }
                if case .profile(let mapping) = receipt { replacementMapping = mapping }
                return receipt
            } catch {
                if !stopping, !Task.isCancelled, guardedMutation?.id == id, probeConfigurationEpoch == epoch,
                   let safe = error as? PublishingVideoMutationAdmissionError { throw safe }
                // Only this external waiter may stop: shutdown joins pending.
                let wasStopping = stopping
                await stop()
                if Task.isCancelled { throw CancellationError() }
                if wasStopping { throw PublisherError.notPublishing }
                throw error
            }
        } onCancel: {
            pending.cancel()
            Task { await self.stop() }
        }
    }

    /// Permanently selects the owned route for this publisher, including when the
    /// subsequent read fails. Context acquisition does not allocate native work.
    public func captureOwnedProbeContext(matching selected: PublishingBitRateChange) async throws -> PublishingBandwidthProbeContext {
        guard !stopping, activeGeneration != nil else { throw PublishingBandwidthProbeError.notPublishing }
        guard probeOwner == nil, probeOperation == nil, probeRetirement == nil,
              !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        ownedProbeMode = true
        let context = PublishingBandwidthProbeContext(issuer: probeContextIssuer, epoch: probeConfigurationEpoch, selected: selected)
        try await validateOwnedProbeContext(context)
        try checkProbeContext(context)
        return context
    }

    /// Point-in-time validation only; later operations must recheck configuration.
    public func validateOwnedProbeContext(_ context: PublishingBandwidthProbeContext) async throws {
        try checkProbeContext(context)
        let healthy = await isPublishing()
        try checkProbeContext(context)
        guard healthy else { throw PublishingBandwidthProbeError.notPublishing }
        // The current native receipt, read after health, detects implicit encoder
        // invalidation too. Historical startup evidence or cached writes cannot.
        let current = await stream.verifiedVideoBitRateReceipt
        try checkProbeContext(context)
        guard let current, context.matches(current) else { throw PublishingBandwidthProbeError.obsolete }
    }

    private func checkProbeContext(_ context: PublishingBandwidthProbeContext) throws {
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard ownedProbeMode, context.issuer == probeContextIssuer, context.epoch == probeConfigurationEpoch,
              context.lower == nil, context.selected.publishingGeneration == generation,
              !encoderUpdating else { throw PublishingBandwidthProbeError.obsolete }
    }

    public func beginOwnedBandwidthProbe(in context: PublishingBandwidthProbeContext, bitRate: Int,
        policy: PublishingBandwidthProbeSnapshot.Policy = .localZeroLoss) throws -> PublishingBandwidthProbeOperation {
        try makeOwnedProbe(in: context, after: nil, request: .init(kind: .begin, bitRate: bitRate, policy: policy, budget: probeBudget))
    }
    public func replaceOwnedBandwidthProbe(after receipt: PublishingBandwidthProbeRetirement,
        in context: PublishingBandwidthProbeContext, bitRate: Int) throws -> PublishingBandwidthProbeOperation {
        try makeOwnedProbe(in: context, after: receipt, request: .init(kind: .replace, bitRate: bitRate, policy: receipt.policy, budget: probeBudget))
    }
    public func restartOwnedBandwidthProbe(after receipt: PublishingBandwidthProbeRetirement,
        in context: PublishingBandwidthProbeContext, bitRate: Int) throws -> PublishingBandwidthProbeOperation {
        try makeOwnedProbe(in: context, after: receipt, request: .init(kind: .restart, bitRate: bitRate, policy: receipt.policy, budget: probeBudget))
    }
    private func makeOwnedProbe(in context: PublishingBandwidthProbeContext, after receipt: PublishingBandwidthProbeRetirement?,
        request: PublishingOwnedProbeRequest) throws -> PublishingBandwidthProbeOperation {
        // Every throw precedes reservation. This exact typed proof permits the
        // upper owner to distinguish native preflight rejection from unknown work.
        let canProveNoReservation = receipt.map { ownedProbeOperation?.owns($0) == true && $0.isAvailable }
            ?? (ownedProbeOperation == nil)
        do {
            try checkProbeContext(context)
            try validateOwnedReservation(current: ownedProbeOperation, issuer: probeContextIssuer,
                context: context, receipt: receipt, request: request, budget: probeBudget)
            try receipt?.consume()
        } catch {
            guard canProveNoReservation else { throw publishingProbeError(error) }
            throw PublishingOwnedFactoryRejection(context: context, predecessor: receipt,
                request: request, reason: publishingProbeError(error))
        }
        let stream = stream
        let operation = PublishingBandwidthProbeOperation(issuer: probeContextIssuer, context: context,
            request: request, predecessor: receipt, backend: .native(.init(
                validate: { [weak self] id in
                    guard let self else { throw PublishingBandwidthProbeError.obsolete }
                    try await self.validateOwnedProbe(context, operationID: id)
                }, allocate: { request, prior in
                    let result: SRTBandwidthProbeSnapshot
                    if let prior {
                        if request.kind == .replace {
                            result = try await stream.replaceBandwidthProbe(id: prior.id, publishingGeneration: prior.publishingGeneration,
                                stage: prior.stage!, bitRate: request.bitRate)
                        } else {
                            result = try await stream.restartBandwidthProbe(id: prior.id, publishingGeneration: prior.publishingGeneration,
                                stage: prior.stage!, bitRate: request.bitRate)
                        }
                    } else {
                        result = try await stream.beginBandwidthProbe(bitRate: request.bitRate,
                            publishingGeneration: context.selected.publishingGeneration, staged: true, repeatable: true, policy: request.policy)
                    }
                    return PublishingBandwidthProbeSnapshot(result)
                }, renew: { PublishingBandwidthProbeSnapshot(try await stream.renewBandwidthProbe(id: $0, publishingGeneration: $1)) },
                cancel: { try? await stream.cancelBandwidthProbe(id: $0, publishingGeneration: $1) },
                retire: { PublishingBandwidthProbeSnapshot(try await stream.retireBandwidthProbe(id: $0, publishingGeneration: $1)) })))
        ownedProbeOperation = operation
        operation.start()
        return operation
    }
    private func validateOwnedProbe(_ context: PublishingBandwidthProbeContext, operationID: UUID) async throws {
        guard ownedProbeOperation?.id == operationID else { throw PublishingBandwidthProbeError.obsolete }
        try await validateOwnedProbeContext(context)
        guard ownedProbeOperation?.id == operationID else { throw PublishingBandwidthProbeError.obsolete }
        try checkProbeContext(context)
    }

    public func beginBandwidthProbe(bitRate: Int, staged: Bool = false, repeatable: Bool = false, policy: PublishingBandwidthProbeSnapshot.Policy = .localZeroLoss) async throws -> PublishingBandwidthProbeSnapshot {
        guard !ownedProbeMode else { throw PublishingBandwidthProbeError.busy }
        guard (!repeatable || staged), (policy == .localZeroLoss || staged) else { throw PublishingBandwidthProbeError.obsolete }
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, probeIdentity == nil, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) { owner in
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.beginBandwidthProbe(
                    bitRate: bitRate, publishingGeneration: generation, staged: staged, repeatable: repeatable, policy: policy))
                owner.capture(value)
                guard value.budget == self.probeBudget, value.publishingGeneration == generation, value.isValidStart(staged: staged, bitRate: bitRate, repeatable: repeatable, policy: policy) else {
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func renewBandwidthProbe(id: UUID, publishingGeneration: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        guard !ownedProbeMode else { throw PublishingBandwidthProbeError.busy }
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard generation == publishingGeneration, let prior = probeIdentity, prior.id == id,
              prior.publishingGeneration == generation else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) { owner in
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.renewBandwidthProbe(id: id, publishingGeneration: generation))
                owner.capture(value)
                guard value.isValidRenewal(of: prior) else {
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func replaceBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32,
                                      bitRate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        guard !ownedProbeMode else { throw PublishingBandwidthProbeError.busy }
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard generation == publishingGeneration, let prior = probeIdentity, prior.id == id,
              prior.publishingGeneration == generation, prior.stage == stage else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) { owner in
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.replaceBandwidthProbe(
                    id: id, publishingGeneration: generation, stage: stage, bitRate: bitRate))
                owner.capture(value)
                guard value.isValidReplacement(of: prior, bitRate: bitRate) else {
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    /// Begin fresh measurements after the exact v3 native owner is terminal.
    /// Requires repeatable opt-in from the first probe and a campaign-aware receiver.
    public func restartBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32,
                                      bitRate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        guard !ownedProbeMode else { throw PublishingBandwidthProbeError.busy }
        guard !stopping, let generation = activeGeneration else { throw PublishingBandwidthProbeError.notPublishing }
        guard generation == publishingGeneration, let prior = probeIdentity, prior.id == id,
              prior.publishingGeneration == generation, prior.stage == stage else { throw PublishingBandwidthProbeError.obsolete }
        guard let campaign = prior.campaign, campaign > 0, campaign < UInt32.max else { throw PublishingBandwidthProbeError.obsolete }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeOperation == nil, !probeRetiring, !probeCleanupFailed, !encoderUpdating else { throw PublishingBandwidthProbeError.busy }
        let revision = probeRevision
        return try await runProbeOperation(generation: generation, revision: revision) { owner in
            try await self.performProbeOperation(generation: generation, revision: revision) {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let value = PublishingBandwidthProbeSnapshot(try await self.stream.restartBandwidthProbe(
                    id: id, publishingGeneration: generation, stage: stage, bitRate: bitRate))
                owner.capture(value)
                guard value.isValidRestart(of: prior, bitRate: bitRate,
                    requestedAt: requestedAt, observedAt: ProcessInfo.processInfo.systemUptime) else {
                    throw PublishingBandwidthProbeError.obsolete
                }
                return value
            }
        }
    }

    public func cancelBandwidthProbe(id: UUID, publishingGeneration: UInt64) async {
        guard !ownedProbeMode else { return }
        guard let owner = probeOwner, owner.matches(id: id, generation: publishingGeneration),
              let target = owner.target else { return }
        probeRevision &+= 1
        probeOperation?.cancel()
        try? await stream.cancelBandwidthProbe(id: target.id, publishingGeneration: target.generation)
    }

    /// Revoke immediately and join only work captured for this exact owner.
    /// A failed replacement receipt also recognizes its predecessor, so a caller
    /// that never received the replacement UUID can still join its cleanup.
    public func retireBandwidthProbe(id: UUID, publishingGeneration: UInt64) async throws {
        guard !ownedProbeMode else { throw PublishingBandwidthProbeError.busy }
        if let retirement = probeRetirement, retirement.owner.matches(id: id, generation: publishingGeneration) {
            try await retirement.task.value
            return
        }
        guard let owner = probeOwner, owner.matches(id: id, generation: publishingGeneration) else {
            throw PublishingBandwidthProbeError.obsolete
        }
        guard !probeRetiring else { throw PublishingBandwidthProbeError.busy }
        probeRetiring = true
        probeRevision &+= 1
        let operation = probeOperation
        operation?.cancel()
        let target = owner.target
        let task = Task {
            defer {
                if self.probeRetirement?.owner === owner { self.probeRetiring = false }
            }
            if let target { try? await self.stream.cancelBandwidthProbe(id: target.id, publishingGeneration: target.generation) }
            _ = await operation?.result
            try await self.joinProbeOwner(owner)
        }
        probeRetirement = (owner, task)
        try await task.value
    }

    public func bandwidthProbeSnapshot() async -> PublishingBandwidthProbeSnapshot? {
        await stream.bandwidthProbeSnapshot.map(PublishingBandwidthProbeSnapshot.init)
    }

    private func invalidateBandwidthProbe() async {
        await ownedProbeOperation?.cancel()
        probeRevision &+= 1
        if let target = probeOwner?.target {
            try? await stream.cancelBandwidthProbe(id: target.id, publishingGeneration: target.generation)
        }
    }

    private func performProbeOperation(generation: UInt64, revision: UInt64,
        operation: @Sendable () async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let healthy = await isPublishing()
        guard healthy, !stopping, activeGeneration == generation else { throw PublishingBandwidthProbeError.notPublishing }
        guard !Task.isCancelled else { throw PublishingBandwidthProbeError.cancelled }
        guard probeRevision == revision, !encoderUpdating else { throw PublishingBandwidthProbeError.obsolete }
        let value = try await operation()
        // An allocator can return after revocation while ignoring cancellation.
        // Retire its captured raw handle before another health read can suspend.
        guard !stopping, activeGeneration == generation, !Task.isCancelled,
              probeRevision == revision, !encoderUpdating else {
            throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
        }
        let stillHealthy = await isPublishing()
        guard stillHealthy, !stopping, activeGeneration == generation,
              !Task.isCancelled, probeRevision == revision, !encoderUpdating else {
            throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
        }
        return value
    }

    private func joinProbeOwner(_ owner: PublishingProbeOperationOwner) async throws {
        do {
            let stream = stream
            try await owner.join(retire: { id, generation in
                _ = try await stream.retireBandwidthProbe(id: id, publishingGeneration: generation)
            }, cancel: { id, generation in
                try? await stream.cancelBandwidthProbe(id: id, publishingGeneration: generation)
            }).value
        } catch {
            // A real failed join remains a cleanup obligation. Never discard it
            // by admitting another probe; stop remains available to close/join.
            if probeOwner === owner { probeCleanupFailed = true }
            throw error
        }
    }

    private func runProbeOperation(generation: UInt64, revision: UInt64,
        _ operation: @escaping @Sendable (PublishingProbeOperationOwner) async throws -> PublishingBandwidthProbeSnapshot) async throws -> PublishingBandwidthProbeSnapshot {
        let owner = PublishingProbeOperationOwner(predecessor: probeIdentity)
        probeOwner = owner
        let pending = Task {
            do { return try await operation(owner) }
            catch {
                if self.probeOwner === owner, self.probeRevision == revision { self.probeRevision &+= 1 }
                // Preserve the operation error; a retirement caller separately
                // observes any cleanup failure through the same retained task.
                _ = try? await self.joinProbeOwner(owner)
                throw error
            }
        }
        probeOperation = pending
        defer { if probeOwner === owner { probeOperation = nil } }
        return try await withTaskCancellationHandler {
            do {
                let value = try await pending.value
                guard !Task.isCancelled, !stopping, activeGeneration == generation,
                      probeRevision == revision, !encoderUpdating else {
                    _ = try? await joinProbeOwner(owner)
                    throw Task.isCancelled ? PublishingBandwidthProbeError.cancelled : .obsolete
                }
                probeIdentity = value
                owner.accept()
                // Keep the old public retirement inert through suspended restart,
                // and discard it only when the new allocation is accepted.
                if let prior = probeRetirement, !prior.owner.matches(id: value.id, generation: value.publishingGeneration) {
                    probeRetirement = nil
                }
                return value
            } catch { throw publishingProbeError(error) }
        } onCancel: { pending.cancel() }
    }

    public func transportClock() async -> PublishingTransportClock? {
        guard !stopping, !Task.isCancelled, let generation = activeGeneration else { return nil }
        let healthy = await isPublishing()
        guard healthy, !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let snapshot = await stream.transportClockSnapshot
        guard !stopping, !Task.isCancelled, activeGeneration == generation,
              let snapshot, snapshot.publishingGeneration == generation else { return nil }
        return PublishingTransportClock(sourceOrigin: snapshot.clock.origin,
                                        publishingGeneration: snapshot.publishingGeneration)
    }

    public func transportStatistics() async -> PublishingTransportStatistics? {
        guard !stopping, !Task.isCancelled, let generation = activeGeneration else { return nil }
        let healthy = await isPublishing()
        guard healthy, !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let stats = await connection.samplePerformanceData()
        guard !stopping, !Task.isCancelled, activeGeneration == generation else { return nil }
        let stillHealthy = await isPublishing()
        guard stillHealthy, !stopping, !Task.isCancelled, activeGeneration == generation,
              let stats, let sampledAt = stats.sampledAt else { return nil }
        return .init(publishingGeneration: generation, sampledAt: sampledAt,
            elapsedMilliseconds: stats.msTimeStamp, sentBytes: stats.byteSentTotal,
            retransmittedBytes: stats.byteRetransTotal, droppedPackets: stats.pktSndDropTotal,
            rttMilliseconds: stats.msRTT, estimatedBandwidthMbps: stats.mbpsBandwidth,
            senderBufferedBytes: stats.byteSndBuf, senderBufferMilliseconds: stats.msSndBuf,
            availableSenderBytes: stats.byteAvailSndBuf, senderDeliveryDelayMilliseconds: stats.msSndTsbPdDelay,
            senderMaximumBandwidthMbps: stats.mbpsMaxBW, packetSendPeriodMicroseconds: stats.usPktSndPeriod)
    }

    public func metrics() async -> (Double, Int32, UInt64)? {
        guard let stats = await connection.performanceData else { return nil }
        return (stats.msRTT, stats.pktSndDropTotal, stats.byteSentTotal)
    }
    public func isPublishing() async -> Bool {
        let connected = await connection.connected
        let publishing = await stream.readyState == .publishing
        let muxerError = await stream.muxerError
        let streamError = await stream.publishingError
        let transportError = await connection.publishingError
        let rawDrops = healthObserver == nil ? nil : await stream.rawVideoFramesDropped
        let snapshot = HealthSnapshot(connected: connected, streamPublishing: publishing,
            muxerError: muxerError, streamError: streamError, transportError: transportError, rawVideoFramesDropped: rawDrops)
        healthObserver?(snapshot)
        return snapshot.isPublishing
    }
    public func stop() async {
        probeConfigurationEpoch = UUID()
        stopping = true
        replacementMapping = nil
        activeGeneration = nil
        if let shutdown { await shutdown.value; return }
        let changing = profileChange
        let guarded = guardedMutation?.task
        let starting = startup
        let probing = probeOperation
        let retirement = probeRetirement?.task
        let owned = ownedProbeOperation
        owned?.revoke()
        probing?.cancel()
        changing?.cancel()
        guarded?.cancel()
        starting?.cancel()
        let pending = Task {
            // Keep the raw health predicate available to the drain policy after
            // admission closes. Join native replacement even when health failed.
            lastStopOutcome = await stopPolicy.run(operations: .init(
                isPublishing: { await self.isPublishing() },
                finish: { await self.stream.finish(timeout: $0) },
                snapshot: { await self.stopSnapshot() },
                close: {
                    await self.stream.close()
                    await self.connection.close()
                }))
            _ = await changing?.result
            _ = await guarded?.result
            _ = await starting?.result
            _ = await probing?.result
            _ = await retirement?.result
            if let owned { _ = try? await owned.retire() }
            if starting != nil || changing != nil || guarded != nil || probing != nil || owned != nil {
                // A native actor call admitted before shutdown can complete after
                // the first close. Its owner must finish before this final close.
                await stream.close()
                await connection.close()
            }
            videoCost?.close()
            startupEvidence.close()
        }
        shutdown = pending
        await pending.value
    }

    private func stopSnapshot() async -> SRTStopPolicy.Snapshot? {
        // finish() normally leaves the stream idle. Its terminal errors and the
        // connection remain meaningful; isPublishing() would be false here.
        guard await connection.connected, await stream.muxerError == nil,
              await stream.publishingError == nil, await connection.publishingError == nil else {
            return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0)
        }
        do {
            // Fresh socket options directly measure the drain boundary.
            guard let packets = try await connection.getSocketOption(.snddata),
                  let latency = try await connection.getSocketOption(.peerlatency) else { return nil }
            // Socket reads suspend this actor. A close may have replaced the
            // socket since the first health check, so recheck before accepting it.
            guard await connection.connected, await stream.muxerError == nil,
                  await stream.publishingError == nil, await connection.publishingError == nil else {
                return .init(healthy: false, unacknowledgedPackets: 0, peerLatencyMilliseconds: 0)
            }
            return .init(healthy: true, unacknowledgedPackets: packets.intValue,
                         peerLatencyMilliseconds: latency.intValue)
        } catch { return nil }
    }
}

public func copyPCM(_ sample: CMSampleBuffer) -> (AVAudioPCMBuffer, AVAudioTime)? {
    guard let description = sample.formatDescription,
          CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM,
          sample.numSamples > 0, sample.numSamples <= Int32.max else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    let pts = sample.presentationTimeStamp
    guard pts.isNumeric, pts.epoch == 0, pts.seconds.isFinite, pts.seconds >= 0,
          pts.seconds < AVAudioTime.seconds(forHostTime: UInt64.max),
          format.sampleRate.isFinite, format.sampleRate > 0,
          format.sampleRate <= Double(Int32.max), format.sampleRate.rounded() == format.sampleRate else { return nil }
    let sampleTime = CMTimeConvertScale(pts, timescale: Int32(format.sampleRate), method: .default)
    guard sampleTime.isNumeric, sampleTime.value >= 0 else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(sample.numSamples)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else { return nil }
    // The SDK anchors encoded audio to hostTime and interprets sampleTime at the
    // PCM format's rate. Preserve both clocks even when capture uses another scale.
    return (buffer, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: pts.seconds),
        sampleTime: sampleTime.value, atRate: format.sampleRate))
}
