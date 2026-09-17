import Combine
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Immutable historical mapping owned by exactly one observation attempt.
struct PublishingClockObservation: Equatable, Sendable {
    let scope: VideoFrameObservationScope
    let transportClock: PublishingTransportClock
    let isClosed: Bool
}

/// Control-plane waits run independently from FilmModel's archive health loop.
/// Only a synchronous tap is shared with capture. No network operation owns it.
@MainActor final class CaptureStreamingModel: ObservableObject {
    enum LocalState: String { case idle, starting, publishing, failed }
    @Published var endpoint = "http://localhost:18787"
    @Published var installationToken = ""
    @Published var workerId = "local-worker"
    @Published var outputId = "local-output"
    @Published private(set) var localState: LocalState = .idle
    @Published private(set) var message: String?
    @Published private(set) var connectedGameID: String?
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var needsStorageRetry = false
    @Published private(set) var commandState: BroadcastCoordinatorState?
    @Published private(set) var workerState: WorkerMediaState = .unknown
    @Published private(set) var workerDecodedVideoFreshness: WorkerDecodedVideoFreshness?
    private(set) var workerDecoderCadenceFreshness: WorkerDecoderCadenceFreshness?
    private(set) var workerDecoderDeliveryFreshness: WorkerDecoderDeliveryFreshness? {
        didSet {
            if let delivery = workerDecoderDeliveryFreshness, deliveryAuthority?.permits(delivery) == true { return }
            deliveryAuthority?.revoke()
            deliveryAuthority = workerDecoderDeliveryFreshness.map(PublishingDeliveryAuthority.init)
        }
    }
    private var deliveryAuthority: PublishingDeliveryAuthority?
    deinit { deliveryAuthority?.revoke(); candidateAuthority?.revoke() }
    private var workerDeliveryTracker = WorkerDecoderDeliveryTracker()
    @Published private(set) var workerReceiverProbeFreshness: WorkerReceiverProbeFreshness? {
        didSet {
            if let evidence = workerReceiverProbeFreshness, candidateAuthority?.permits(evidence) == true { return }
            candidateAuthority?.revoke()
            candidateAuthority = workerReceiverProbeFreshness.map(PublishingCandidateAuthority.init)
        }
    }
    private(set) var candidateAuthority: PublishingCandidateAuthority?
    private var probeReadSequence: UInt64 = 0
    private var acceptedProbeReadSequence: UInt64 = 0
    struct MeasuredCandidate: Sendable {
        let measurement: PublishingCandidateAdmission.Measurement
        let binding: PublishingProbeObservation
        let probe: PublishingProbeObservation
        let boundAt: Double
        let completedAt: Double
        let permitsCurrentCandidate: @Sendable (UUID) -> Bool
    }
    typealias MeasuredCandidateReader = @MainActor () async -> MeasuredCandidate?
    /// Injection uses the same provider ownership boundary as the explicit lab route.
    /// Ordinary publishing never installs a candidate provider.
    var measuredCandidateFactory: ((any MediaPublisher) -> MeasuredCandidateReader?) = { publisher in
        #if DEBUG && targetEnvironment(simulator)
        guard (try? NativeMeasuredTrialFixture.requested(environment: ProcessInfo.processInfo.environment)) == true,
              let candidate = publisher as? NativeCandidatePublisher else { return nil }
        return {
            guard let snapshot = await candidate.candidateSnapshot() else { return nil }
            return MeasuredCandidate(measurement: .init(snapshot.cost), binding: snapshot.binding, probe: snapshot.probe,
                boundAt: snapshot.boundAt, completedAt: snapshot.completedAt,
                permitsCurrentCandidate: snapshot.permitsCurrentCandidate)
        }
        #else
        return nil
        #endif
    }
    @Published private(set) var workerReceiverProbeInterval: WorkerReceiverProbeInterval?
    private var receiverProbeTracker = WorkerReceiverProbeTracker()
    private var receiverProbeLeaseDeadline: ContinuousClock.Instant?
    private var receiverProbeOwner: PublishingProbeObservation?
    @Published private(set) var workerSourceInterval: WorkerSourceIntervalObservation?
    @Published private(set) var sentSamples = 0
    /// One bounded current or latest closed attempt. Counts are local callback
    /// evidence; a starting snapshot establishes neither applied settings nor readiness.
    @Published private(set) var videoObservation: VideoFrameObservationSnapshot?
    /// Same attempt/anchor as video observations, but closes at ingress cancellation
    /// rather than encoder-drain completion. This is not transport capacity or loss.
    @Published private(set) var ingressObservation: LiveIngressObservationSnapshot?
    /// Historical native clock mapping; closure marks detach, not current readiness.
    @Published private(set) var publishingClockObservation: PublishingClockObservation?
    #if DEBUG
    // Explicit simulator fixture flag; Mac unit tests opt in by injection.
    var workerReportAgeProofsEnabled: Bool = {
        #if targetEnvironment(simulator)
        VideoObservationFixture.requested(environment: ProcessInfo.processInfo.environment)
        #else
        false
        #endif
    }()
    var cadenceReportFixtureWriter: ((Data) async -> Void)? = {
        #if targetEnvironment(simulator)
        guard WorkerCadenceReportAudit.requested(environment: ProcessInfo.processInfo.environment) else { return nil }
        return { await WorkerCadenceReportAudit.persist($0) }
        #else
        return nil
        #endif
    }()
    private var cadenceReportAudit: WorkerCadenceReportAudit?
    private(set) var workerReportAgeProofHistory = WorkerReportAgeProofHistory()
    private var receiverProbeHistory = ReceiverProbeFixtureHistory()
    var receiverProbeFixtureWriter: ((Data) async -> Void)? = {
        #if targetEnvironment(simulator)
        guard ["renew", "expire", "staged"].contains(ProcessInfo.processInfo.environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] ?? "") else { return nil }
        return { await ReceiverProbeFixtureHistory.persist($0) }
        #else
        return nil
        #endif
    }()
    private(set) var workerSourceIntervalHistory: [WorkerSourceIntervalObservation] = []
    var videoObservationFixtureWriter: ((VideoFrameObservationSnapshot, Double, [WorkerReportAgeProof], LiveIngressObservationSnapshot?, PublishingClockObservation?, [WorkerSourceIntervalObservation]) async -> Void)? = {
        #if targetEnvironment(simulator)
        return { snapshot, detached, proofs, ingress, clock, sourceIntervals in
            await VideoObservationFixture.writeClosed(snapshot, captureDetachedAt: detached, workerReportAgeProofs: proofs, ingressObservation: ingress, publishingClockObservation: clock, sourceIntervals: sourceIntervals)
        }
        #else
        return nil
        #endif
    }()
    #endif
    private var diagnosticAttemptID: UUID?
    @Published private(set) var activeRecordingID: String?
    private var workerEpoch = UUID()
    private var workerFreshness: WorkerStatusFreshness?
    private var workerSourceTracker = WorkerSourceIntervalTracker()
    private var setup: SavedCaptureSetup?
    var watchSetupConnection: (endpoint: String, installationToken: String)? {
        guard !needsStorageRetry, let setup, !setup.installationToken.isEmpty else { return nil }
        return (setup.endpoint, setup.installationToken)
    }
    private var restored = false
    private var current: CurrentCapture?
    private var publishing: (context: CurrentCapture, session: PublishingSession, generation: Int, attempt: UUID, observations: VideoFrameObservationOwner?, probeObserver: (any PublishingProbeObserving)?)?
    private var coordinator: BroadcastCommandCoordinator?
    var controlPollInterval: Duration {
        #if DEBUG
        // Probe evidence has a 300-ms observed lease. A two-second status
        // cadence would let local health expire every interval baseline.
        if cadenceReportFixtureWriter != nil || receiverProbeFixtureWriter != nil { return .milliseconds(100) }
        #endif
        return qualityDriver == nil ? .seconds(2) : .milliseconds(100)
    }
    private var qualityDriver: PublishingQualityDriver?
    #if DEBUG
    private var transitionDriver: NativeProfileTransitionDriver?
    private var adaptiveProfileEvidence: NativeProfileTransitionEvidence?
    #endif
    private var action: Task<Void, Never>?
    private var actionID: UUID?
    private var stoppingTask: Task<Void, Never>?
    private var publisherTeardown: Task<Void, Never>?
    private var teardownID: UUID?
    @Published private var publisherStopping = false
    private var epoch = UUID()
    @Published private var controlBusy = false
    private var requestedStart: CurrentCapture?
    private var shouldStopOwnedBroadcast = false
    private var ownedRecordingIDs: Set<String> = []
    private let storage: any CaptureSetupStorage
    private let pendingStore: any PendingBroadcastStore
    private let clientFactory: (ScoringEndpoint) -> MatchHTTPClient
    private let publisherFactory: (URL, VideoFrameObservationOwner?) throws -> any MediaPublisher
    private let observationFactory: (VideoFrameObservationScope) throws -> VideoFrameObservationOwner
    private let qualityFactory: @MainActor (PublishingSession, UUID) throws -> PublishingQualityDriver?

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scorebug", isDirectory: true)
        self.init(storage: CaptureKeychain(), pendingStore: JSONFilePendingBroadcastStore(url: directory.appendingPathComponent("pending-broadcast.json")))
    }
    init(storage: any CaptureSetupStorage, pendingStore: any PendingBroadcastStore,
         clientFactory: @escaping (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         publisherFactory: @escaping (URL, VideoFrameObservationOwner?) throws -> any MediaPublisher = { url, observations in
             #if DEBUG && targetEnvironment(simulator)
             let environment = ProcessInfo.processInfo.environment
             let measuredTrial = try NativeMeasuredTrialFixture.requested(environment: environment)
             let candidateProfile = try NativeCandidateFixture.requested(environment: environment)
             let candidateHeadroom = try NativeCandidateHeadroomFixture.requested(environment: environment)
             let probeMode = try NativeBandwidthProbePublisher.requested(environment: environment)
             let cadencePacing = try NativeProfileTransitionEvidence.cadencePacingRequested(environment: environment)
             if environment["SCOREBUG_TEST_DECODER_STALL"] == "reset540", WorkerCadenceReportAudit.requested(environment: environment) {
                 guard let observations else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 return NativeProfileTransitionPublisher(url: url, observations: observations, adaptive: true, sequence: .stallReset)
             }
             if try NativeProfileTransitionEvidence.adaptiveRequested(environment: environment) {
                 guard let observations else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 let target = try VideoObservationFixture.publishingURL(url, environment: environment)
                 return NativeProfileTransitionPublisher(url: target, observations: observations, adaptive: true, pacesEncodedVideo: cadencePacing)
             }
             if let sequence = try NativeProfileTransitionEvidence.requestedSequence(environment: environment) {
                 guard let observations else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 return NativeProfileTransitionPublisher(url: url, observations: observations, sequence: sequence)
             }
             let profile = try VideoObservationFixture.liveProfile(environment: environment)
             let target = try VideoObservationFixture.publishingURL(url, environment: environment)
             let proof = VideoObservationFixture.requested(environment: environment) && profile != .hd1080 ? observations.map { NativePublishingFormatFixture(scope: $0.snapshot.scope, profile: profile) } : nil
             let transitions = measuredTrial ? observations.map {
                 NativeProfileTransitionEvidence(scope: $0.snapshot.scope, sequence: .measured)
             } : nil
             let observer: (@Sendable (SRTPublisher.CompressedVideoFrame) -> Void)?
             let didStop: (@Sendable () -> Void)?
             if let proof {
                 observer = { frame in proof.observe(frame); transitions?.observe(frame) }
                 didStop = { proof.persist() }
             }
             else { observer = nil; didStop = nil }
             let candidateTransport: PublishingCandidateTransport?
             let audioObserver: (@Sendable (SRTPublisher.CompressedAudioFrame) -> Void)?
             if let candidateProfile {
                 guard let observations else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 let window = PublishingCandidateTransport(scope: observations.snapshot.scope, profile: candidateProfile)
                 candidateTransport = window; audioObserver = { window.observeAudio($0) }
             } else { candidateTransport = nil; audioObserver = nil }
             let publisher = SRTMediaPublisher(url: target, observations: observations,
                 encoderConfigurationObserver: proof.map { proof in { frame in proof.observeEncoding(frame); transitions?.observeEncoder(frame) } }, videoProfile: profile,
                 compressedVideoObserver: observer, compressedAudioObserver: audioObserver,
                 didStop: didStop, allowsBandwidthProbes: probeMode != nil, videoCost: proof?.videoCost)
             proof?.observeStartup(from: publisher)
             let primary: any MediaPublisher
             if let probeMode {
                 guard let observations else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 primary = NativeBandwidthProbePublisher(publisher: publisher, scope: observations.snapshot.scope,
                     mode: probeMode, candidateHeadroom: candidateHeadroom)
             } else { primary = publisher }
             if let candidateProfile {
                 guard let observations, let candidateTransport else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
                 return try NativeCandidatePublisher(publisher: primary, scope: observations.snapshot.scope, liveProfile: profile,
                     candidate: candidateProfile, transport: candidateTransport, candidateHeadroom: candidateHeadroom,
                     lifecycle: measuredTrial ? NativeCandidateLifecycleAudit(scope: observations.snapshot.scope) : nil,
                     profileReceipt: transitions.map { evidence in { evidence.receipt($0) } },
                     joinedStop: transitions.map { evidence in {
                         evidence.close()
                         if let data = try? evidence.data() { await NativeProfileTransitionEvidence.persist(data) }
                     } })
             }
             return primary
             #else
             return SRTMediaPublisher(url: url, observations: observations, videoProfile: .minimumStartup)
             #endif
         },
         observationFactory: @escaping (VideoFrameObservationScope) throws -> VideoFrameObservationOwner = { scope in
             #if DEBUG && targetEnvironment(simulator)
             let limit = VideoObservationFixture.completedWindowLimit(environment: ProcessInfo.processInfo.environment)
             return try VideoFrameObservationOwner(scope: scope, completedWindowLimit: limit, sourceHistoryCapacity: 2048)
             #else
             return try VideoFrameObservationOwner(scope: scope, sourceHistoryCapacity: 2048)
             #endif
         }, qualityFactory: @escaping @MainActor (PublishingSession, UUID) throws -> PublishingQualityDriver? = {
             try PublishingQualityDriver.fixture(session: $0, attemptID: $1)
         }) {
        self.storage = storage; self.pendingStore = pendingStore
        self.clientFactory = clientFactory; self.publisherFactory = publisherFactory
        self.observationFactory = observationFactory; self.qualityFactory = qualityFactory
    }
    var canStart: Bool { current != nil && !busy && !stopping && !publisherStopping && requestedStart == nil && localState != .publishing && !needsStorageRetry && commandState?.pending == nil }
    var canChangeSetup: Bool {
        guard !busy, !stopping, !publisherStopping, !controlBusy, requestedStart == nil, publishing == nil, !needsStorageRetry else { return false }
        do { return try pendingStore.load() == nil && (setup?.reports.isEmpty ?? true) && (setup?.stopRecordingIDs?.isEmpty ?? true) } catch { return false }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        do {
            setup = try storage.load()
            if var saved = setup {
                _ = try ScoringEndpoint(saved.endpoint)
                endpoint = saved.endpoint; installationToken = saved.installationToken
                workerId = saved.workerId; outputId = saved.outputId
                for index in saved.reports.indices where saved.reports[index].report.status == .recording {
                    saved.reports[index].report.sequence += 1
                    saved.reports[index].report.status = .interrupted
                    saved.reports[index].delivered = false
                }
                setup = saved
                guard (saved.stopRecordingIDs?.count ?? 0) <= 64 else { throw CaptureControlError.storage }
                ownedRecordingIDs = Set(saved.reports.map { $0.report.recordingId } + (saved.stopRecordingIDs ?? []))
                if let pending = try pendingStore.load(), pending.endpointScope == saved.endpointScope,
                   pending.captureDeviceId == saved.deviceId, pending.command.gameId == saved.credential?.gameId,
                   case .start(let selection) = pending.command.operation { ownedRecordingIDs.insert(selection.recordingId) }
                shouldStopOwnedBroadcast = !ownedRecordingIDs.isEmpty
                try persist()
                try makeCoordinator()
            }
        } catch { needsStorageRetry = true; message = "Capture setup could not be restored. Retry to read the saved connection. Local recording is independent." }
    }

    /// Invoked in the same MainActor turn that clears FilmModel's context, before
    /// archive drain, storage, HTTP or encoder awaits. Detach/cancel is immediate.
    func captureChanged(_ context: CurrentCapture?, terminalStatus: RecordingStatus? = .stopped) {
        let previous = current
        if context?.id != previous?.id || context?.tap !== previous?.tap {
            // Revoke before recording/report/control work can suspend, including
            // replacement taps that deliberately reuse a recording identifier.
            candidateAuthority?.revoke()
            if previous != nil, context != nil { clearWorker() }
            workerSourceTracker.clear()
            workerSourceInterval = nil
            #if DEBUG
            if context != nil { workerSourceIntervalHistory = [] }
            #endif
        }
        if let requestedStart, context?.id != requestedStart.id || context?.tap !== requestedStart.tap {
            self.requestedStart = nil
            localState = .idle
            message = "Streaming start canceled because the recording changed."
        }
        current = context
        activeRecordingID = context?.id
        #if DEBUG
        // A closing capture snapshots its old attempt in detachPublisher before
        // clearing; a replacement recording cannot inherit live proof history.
        if context != nil, previous?.id != context?.id { workerReportAgeProofHistory.clear() }
        #endif
        if context == nil {
            epoch = UUID()
            action?.cancel()
            detachPublisher()
            shouldStopOwnedBroadcast = true
            let coordinator = coordinator
            Task { await coordinator?.setActiveRecording(nil) }
            if let previous, let terminalStatus { queueReport(previous, status: terminalStatus) }
        } else if let context {
            ownedRecordingIDs.insert(context.id)
            queueReport(context, status: .recording)
        }
    }

    func captureFinished(_ context: CurrentCapture, interrupted: Bool) {
        queueReport(context, status: interrupted ? .interrupted : .stopped)
    }

    func connect() async {
        guard !busy, !stopping, !publisherStopping, !controlBusy else { return }
        await restore()
        do {
            if setup == nil || endpoint != setup?.endpoint || installationToken != setup?.installationToken || workerId != setup?.workerId || outputId != setup?.outputId {
                guard canChangeSetup else { throw CaptureControlError.unresolved }
                let valid = try ScoringEndpoint(endpoint)
                guard !installationToken.isEmpty, validIdentifier(workerId), validIdentifier(outputId) else { throw CaptureControlError.noSetup }
                setup = SavedCaptureSetup(endpoint: valid.url.absoluteString, installationToken: installationToken,
                    deviceId: setup?.deviceId ?? UUID().uuidString, workerId: workerId, outputId: outputId, credential: nil, reports: [])
                try persist()
                coordinator = nil; connectedGameID = nil; commandState = nil; clearWorker()
            }
            try persist()
            busy = true
            defer { busy = false }
            try await joinActiveMatch()
            message = "Connected to the active match. Record video before starting streaming."
        } catch { fail(error) }
    }

    func startStreaming() async {
        await beginStreaming()?.value
    }

    /// Called synchronously by the button so a poll cannot steal an accepted tap
    /// before an unstructured Task reaches the start guard. Only one intent exists.
    func requestStartStreaming() {
        guard canStart, let context = current else { return }
        if controlBusy {
            requestedStart = context
            localState = .starting
            message = "Waiting for the current connection check before starting streaming."
        } else {
            _ = beginStreaming()
        }
    }

    private func resumeRequestedStart(controlFailed: Bool) {
        guard let requested = requestedStart else { return }
        requestedStart = nil
        guard current?.id == requested.id, current?.tap === requested.tap, !stopping, !publisherStopping else {
            localState = .idle
            return
        }
        guard !controlFailed else { localState = .failed; return }
        guard canStart else {
            localState = .failed
            message = "Streaming could not start while the connection has unresolved changes. Retry the connection, then start streaming again."
            return
        }
        _ = beginStreaming()
    }

    private func beginStreaming() -> Task<Void, Never>? {
        guard !busy, !stopping, !publisherStopping, !controlBusy, requestedStart == nil, publishing == nil, let context = current else { return nil }
        busy = true
        let attempt = UUID(); epoch = attempt; actionID = attempt
        diagnosticAttemptID = attempt; videoObservation = nil; ingressObservation = nil; publishingClockObservation = nil
        localState = .starting; message = nil; clearWorker()
        let task = Task { [self] in
            defer { if actionID == attempt { action = nil; actionID = nil; busy = false } }
            do {
                await restore()
                try check(context, attempt)
                if coordinator == nil { try await joinActiveMatch(); try check(context, attempt) }
                guard let setup, let credential = setup.credential, let coordinator else { throw CaptureControlError.noSetup }
                try reserveStopOwnership(context.id)
                queueReport(context, status: .recording)
                try await flushReports()
                try check(context, attempt)
                var state = try await coordinator.recover(activeRecordingId: context.id)
                try check(context, attempt)
                commandState = state
                guard state.pending == nil else { throw CaptureControlError.unresolved }
                let selection = BroadcastSelection(workerId: setup.workerId, outputId: setup.outputId, captureDeviceId: setup.deviceId, recordingId: context.id)
                if state.snapshot?.broadcast.desired != .running || state.snapshot?.broadcast.selection != selection {
                    state = try await coordinator.submit(.start(selection: selection), activeRecordingId: context.id)
                    try check(context, attempt)
                    commandState = state
                    guard state.outcome?.accepted == true else { throw CaptureControlError.rejected }
                }
                guard let broadcast = state.snapshot?.broadcast, broadcast.desired == .running, broadcast.selection == selection else { throw CaptureControlError.selectionChanged }
                let client = try clientForSetup()
                let access = try await client.publishAccess(recordingId: context.id, generation: broadcast.generation, publishingAttemptId: attempt, credential: credential)
                try check(context, attempt)
                // Measurement starts after the earlier control-plane requests, but
                // includes encoder/transport startup. Revision 1 identifies the existing
                // initial publishing configuration; it does not assert that startup applied it.
                let scope = VideoFrameObservationScope(recordingID: context.id, matchID: credential.gameId,
                    broadcastGeneration: broadcast.generation, publishingAttemptID: attempt, appliedProfileRevision: 1)
                // Unavailable diagnostics must not fail publishing, archive or storage.
                let observations = try? observationFactory(scope)
                videoObservation = observations?.snapshot
                let session: PublishingSession
                let publisher: any MediaPublisher
                do {
                    publisher = try publisherFactory(access.publishUrl, observations)
                    session = try PublishingSession(publisher: publisher,
                        ingressObservation: ingressConfiguration(for: videoObservation))
                    ingressObservation = session.snapshot.ingressObservation
                } catch {
                    videoObservation = observations?.close()
                    throw error
                }
                #if DEBUG
                if let candidate = publisher as? NativeCandidatePublisher {
                    await candidate.setDiagnostics { [weak session] in NativeCandidatePublisher.Pressure(session?.snapshot) }
                    try check(context, attempt)
                }
                #endif
                publishing = (context, session, broadcast.generation, attempt, observations, publisher as? any PublishingProbeObserving)
                guard context.tap.attach(session, observations: observations) else { throw CaptureControlError.recordingStopped }
                try await session.start()
                try check(context, attempt)
                qualityDriver = try qualityFactory(session, attempt)
                if let readCandidate = measuredCandidateFactory(publisher) {
                    qualityDriver?.candidateInputProvider = { [weak self] state in
                        await self?.measuredCandidateInput(state, readCandidate: readCandidate)
                    }
                }
                qualityDriver?.cadenceInputProvider = { [weak self, weak session] in
                    guard let self, let session, let live = self.publishing,
                          live.session === session, live.attempt == attempt,
                          self.localState == .publishing, self.diagnosticAttemptID == attempt,
                          self.activeRecordingID == live.context.id, self.current?.tap === live.context.tap,
                          session.snapshot.state == .publishing, session.snapshot.failure == nil else { return nil }
                    return .init(cadence: self.workerDecoderCadenceFreshness, diagnostics: .init(snapshot: session.snapshot))
                }
                qualityDriver?.deliveryInputProvider = { [weak self] in
                    guard let self, let current = self.publishing, current.attempt == attempt,
                          self.localState == .publishing, self.diagnosticAttemptID == attempt,
                          self.activeRecordingID == current.context.id, self.current?.tap === current.context.tap,
                          let history = current.observations?.sourceHistorySnapshot,
                          let delivery = self.workerDecoderDeliveryFreshness,
                          let clock = current.session.snapshot.transportClock else { return nil }
                    return .init(history: history, clock: .init(scope: history.scope, transportClock: clock, isClosed: false),
                        diagnostics: .init(snapshot: current.session.snapshot), delivery: delivery, authority: self.deliveryAuthority)
                }
                #if DEBUG
                cadenceReportAudit = cadenceReportFixtureWriter == nil ? nil : WorkerCadenceReportAudit()
                if let fixture = publisher as? NativeProfileTransitionPublisher {
                    if fixture.adaptive { adaptiveProfileEvidence = fixture.evidence }
                    else { transitionDriver = NativeProfileTransitionDriver(session: session, evidence: fixture.evidence) }
                }
                #endif
                localState = .publishing
                shouldStopOwnedBroadcast = false
                message = "Sending camera media. Worker output is reported separately."
            } catch {
                if epoch == attempt { detachPublisher(); localState = .failed; shouldStopOwnedBroadcast = true; fail(error) }
                if let coordinator { commandState = await coordinator.state() }
            }
        }
        action = task
        return task
    }

    func stopStreaming() async {
        requestedStart = nil
        if let stoppingTask { await stoppingTask.value; return }
        stopping = true
        epoch = UUID()
        let priorAction = action, priorActionID = actionID
        priorAction?.cancel()
        detachPublisher()
        let teardown = publisherTeardown
        shouldStopOwnedBroadcast = true
        let coordinator = coordinator
        let task = Task { [self] in
            await coordinator?.setActiveRecording(nil)
            await teardown?.value
            await priorAction?.value
            if actionID == priorActionID { action = nil; actionID = nil; busy = false }
            await pollControl()
        }
        stoppingTask = task
        await task.value
        stoppingTask = nil
        stopping = false
    }

    /// A separate modest timer drives this method. A delayed request never blocks
    /// camera health. Local state and observation expiry use pollLocalHealth().
    func pollControl() async {
        if needsStorageRetry && setup == nil { restored = false }
        await restore()
        // Defer the owned broadcast stop until publisher finish settles. Each
        // control await can reenter a local stop on MainActor.
        guard !busy, !controlBusy, !publisherStopping, let setup, setup.credential != nil else { return }
        controlBusy = true
        var controlFailed = false
        defer {
            controlBusy = false
            resumeRequestedStart(controlFailed: controlFailed)
        }
        do {
            try persist()
            if coordinator == nil { try makeCoordinator() }
            try await flushReports()
            guard !publisherStopping, let coordinator else { return }
            var state = try await coordinator.recover(activeRecordingId: shouldStopOwnedBroadcast ? nil : current?.id)
            guard !publisherStopping else { return }
            commandState = state
            if shouldStopOwnedBroadcast {
                if state.pending != nil {
                    do { state = try await coordinator.discardExpired(); commandState = state }
                    catch BroadcastCoordinatorError.notExpired { return }
                }
                guard !publisherStopping else { return }
                if state.pending == nil, let selection = state.snapshot?.broadcast.selection,
                   state.snapshot?.broadcast.desired == .running, selection.captureDeviceId == setup.deviceId,
                   ownedRecordingIDs.contains(selection.recordingId) {
                    state = try await coordinator.submit(.stop, activeRecordingId: current?.id, requiredStopSelection: selection)
                    commandState = state
                }
                if state.pending == nil, let broadcast = state.snapshot?.broadcast,
                   broadcast.desired == .stopped || broadcast.selection.map({
                       $0.captureDeviceId != setup.deviceId || !ownedRecordingIDs.contains($0.recordingId)
                   }) == true {
                    setupClearStopOwnership()
                    try persist()
                    shouldStopOwnedBroadcast = false
                }
            }
            if let publishing {
                let broadcast = state.snapshot?.broadcast
                if broadcast?.desired != .running || broadcast?.generation != publishing.generation || broadcast?.selection?.recordingId != publishing.context.id || broadcast?.selection?.captureDeviceId != setup.deviceId {
                    detachPublisher()
                    message = "Streaming selection ended or changed. Recording continues on this device."
                }
            }
            guard let credential = setup.credential else { return }
            let observedEpoch = workerEpoch
            let requestStartedAtUptime = ProcessInfo.processInfo.systemUptime
            let requestStart = ContinuousClock.now
            let response: WorkerMediaStatusResponse
            do {
                let deliveryRequest: DecoderDeliveryRequest? = publishing == nil ? nil :
                    workerDeliveryTracker.cursor.map(DecoderDeliveryRequest.after) ?? .full
                response = try await clientForSetup().workerStatus(credential: credential, delivery: deliveryRequest)
            } catch {
                // A stopped attempt no longer owns either successes or failures.
                guard observedEpoch == workerEpoch else { return }
                throw error
            }
            guard observedEpoch == workerEpoch else { return }
            guard response.status.gameId == credential.gameId, response.status.generation == commandState?.snapshot?.broadcast.generation,
                  response.status.workerId == commandState?.snapshot?.broadcast.selection?.workerId else { clearWorker(); return }
            let received = ContinuousClock.now
            let responseReceivedAtUptime = ProcessInfo.processInfo.systemUptime
            let requestDuration = requestStart.duration(to: received)
            // Read sender acceptance after the receiver response; earlier local
            // counts could legitimately lag bytes already observed by the relay.
            let probeReadStartedAt = ProcessInfo.processInfo.systemUptime
            let readSequence = nextProbeReadSequence()
            let observedProbe = await publishing?.probeObserver?.probeObservation()
            let probeReadFinishedAt = ProcessInfo.processInfo.systemUptime
            guard observedEpoch == workerEpoch else { return }
            let probe = acceptProbeObservation(observedProbe, sequence: readSequence)
            // A response whose native join was overtaken has no truthful native
            // read bracket for the newer proof. Preserve current evidence and
            // wait for the next control response instead of relabelling it.
            guard acceptedProbeReadSequence == readSequence else { return }
            updateReceiverProbe(response: response, probe: probe, receivedAt: received, requestDuration: requestDuration,
                requestStartedAtUptime: requestStartedAtUptime, responseReceivedAtUptime: responseReceivedAtUptime,
                probeReadStartedAt: probeReadStartedAt, probeReadFinishedAt: probeReadFinishedAt)
            workerFreshness = WorkerStatusFreshness(response: response, receivedAt: received, requestDuration: requestDuration)
            workerDecodedVideoFreshness = WorkerDecodedVideoFreshness(response: response, receivedAt: received, requestDuration: requestDuration)
            if let publishing, localState == .publishing,
               publishing.attempt == diagnosticAttemptID, activeRecordingID == publishing.context.id,
               current?.tap === publishing.context.tap, response.status.validatedPublication != nil {
                workerDecoderDeliveryFreshness = workerDeliveryTracker.observe(response: response,
                    expectedPublishingAttemptID: publishing.attempt, receivedAt: received, requestDuration: requestDuration)
                workerDecoderCadenceFreshness = WorkerDecoderCadenceFreshness(response: response,
                    expectedPublishingAttemptID: publishing.attempt, receivedAt: received, requestDuration: requestDuration)
                if let history = publishing.observations?.sourceHistorySnapshot {
                    workerSourceInterval = workerSourceTracker.observe(response: response, history: history,
                        clock: clockObservation(publishing.session.snapshot.transportClock, scope: history.scope, isClosed: false),
                        receivedAt: received, requestDuration: requestDuration)
                } else { workerSourceTracker.clear(); workerSourceInterval = nil }
            } else {
                workerDecoderCadenceFreshness = nil
                workerDeliveryTracker.unavailable(); workerDecoderDeliveryFreshness = nil
                workerSourceTracker.clear()
                workerSourceInterval = nil
            }
            #if DEBUG
            if let publishing, localState == .publishing, publishing.attempt == diagnosticAttemptID {
                let evaluatedUptime = ProcessInfo.processInfo.systemUptime, evaluated = ContinuousClock.now
                cadenceReportAudit?.record(response: response, expectedAttempt: publishing.attempt,
                    helper: workerDecoderCadenceFreshness, delivery: workerDecoderDeliveryFreshness, receivedAt: received, requestDuration: requestDuration,
                    receivedUptime: responseReceivedAtUptime, instant: evaluated, evaluatedUptime: evaluatedUptime)
            }
            if workerReportAgeProofsEnabled, let interval = workerSourceInterval {
                let previous = workerSourceIntervalHistory.last
                if previous?.sequence != interval.sequence || previous?.workerEpoch != interval.workerEpoch ||
                    previous?.workerAttempt != interval.workerAttempt || previous?.publication != interval.publication {
                    workerSourceIntervalHistory.append(interval)
                    if workerSourceIntervalHistory.count > 128 { workerSourceIntervalHistory.removeFirst() }
                } else if !workerSourceIntervalHistory.isEmpty {
                    // Keep the original source/age anchor while recording later completion evidence.
                    workerSourceIntervalHistory[workerSourceIntervalHistory.count - 1].processing = interval.processing
                }
            }
            if workerReportAgeProofsEnabled, let publishing, localState == .publishing,
               publishing.attempt == diagnosticAttemptID, activeRecordingID == publishing.context.id,
               let scope = publishing.observations?.snapshot.scope {
                // One evaluation instant, one call to the actual helper. Preserve
                // its return; export must never recompute or imply current age.
                let evaluated = ContinuousClock.now
                let actualAge = workerDecodedVideoFreshness?.ageUpperBound(at: evaluated)
                workerReportAgeProofHistory.record(WorkerReportAgeProof(scope: scope,
                    helper: workerDecodedVideoFreshness,
                    serverUpperBoundMs: response.status.decodedVideoAgeUpperBoundMs,
                    requestDuration: requestDuration, residenceDuration: received.duration(to: evaluated),
                    helperAgeUpperBound: actualAge))
            } else { workerReportAgeProofHistory.clear() }
            #endif
            // A newly completed worker report need not wait for the next health
            // tick. The driver coalesces both callers into the same owned task.
            if let publishing, let qualityDriver {
                qualityDriver.tick(encoderReady: publishing.observations?.sourceHistorySnapshot?.encoded.isEmpty == false,
                    source: workerSourceInterval, cadence: workerDecoderCadenceFreshness, diagnostics: .init(snapshot: publishing.session.snapshot))
            }
            workerState = workerFreshness?.isFresh() == true ? response.status.state : .stale
        } catch {
            controlFailed = true
            clearWorker()
            if publishing != nil { detachPublisher(); localState = .failed; shouldStopOwnedBroadcast = true }
            if let coordinator { commandState = await coordinator.state() }
            fail(error)
        }
    }

    func pollLocalHealth(at instant: ContinuousClock.Instant = .now) {
        workerDeliveryTracker.expire(at: instant)
        workerDecoderDeliveryFreshness = workerDeliveryTracker.latest
        receiverProbeTracker.expire(at: instant)
        workerReceiverProbeInterval = receiverProbeTracker.latest
        if receiverProbeLeaseDeadline.map({ instant < $0 }) != true ||
            receiverProbeOwner?.isActive(at: ProcessInfo.processInfo.systemUptime) != true {
            receiverProbeTracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: instant)
            receiverProbeLeaseDeadline = nil; receiverProbeOwner = nil
            workerReceiverProbeFreshness = nil; workerReceiverProbeInterval = nil
        }
        if workerReceiverProbeFreshness?.snapshotAgeUpperBound(at: instant).map({ $0 <= WorkerReceiverProbeTracker.maximumAge }) != true ||
            workerReceiverProbeFreshness?.lastDeliveryAgeUpperBound(at: instant).map({ $0 <= WorkerReceiverProbeTracker.maximumAge }) != true {
            workerReceiverProbeFreshness = nil
        }
        workerSourceTracker.expire(at: instant)
        workerSourceInterval = workerSourceTracker.latest
        if workerFreshness?.isFresh(at: instant) == false {
            workerState = .stale; workerFreshness = nil; workerDecodedVideoFreshness = nil; workerDecoderCadenceFreshness = nil
            #if DEBUG
            workerReportAgeProofHistory.clear()
            #endif
        }
        guard let publishing else { return }
        videoObservation = publishing.observations?.poll()
        let snapshot = publishing.session.snapshot
        sentSamples = snapshot.sentSamples
        ingressObservation = snapshot.ingressObservation
        publishingClockObservation = clockObservation(snapshot.transportClock,
            scope: videoObservation?.scope, isClosed: false)
        qualityDriver?.tick(encoderReady: publishing.observations?.sourceHistorySnapshot?.encoded.isEmpty == false,
            source: workerSourceInterval, cadence: workerDecoderCadenceFreshness, diagnostics: .init(snapshot: snapshot))
        if snapshot.failure != nil || snapshot.state == .stopped {
            detachPublisher(); shouldStopOwnedBroadcast = true
            localState = .failed
            message = "Camera publishing stopped. Your local recording continues. Retry streaming when the connection is ready."
        }
    }

    private func nextProbeReadSequence() -> UInt64 {
        probeReadSequence += 1
        return probeReadSequence
    }

    /// A bounded latest native sample. A late reader can use newer accepted
    /// ownership, but cannot move its byte count, stage or lease backwards.
    @discardableResult private func acceptProbeObservation(_ value: PublishingProbeObservation?, sequence: UInt64) -> PublishingProbeObservation? {
        guard sequence > acceptedProbeReadSequence else { return receiverProbeOwner }
        let instant = ContinuousClock.now, now = ProcessInfo.processInfo.systemUptime
        guard let value, value.isActive(at: now),
              value.publishingGeneration == publishing?.session.snapshot.transportClock?.publishingGeneration else {
            acceptedProbeReadSequence = sequence
            receiverProbeTracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: instant)
            receiverProbeLeaseDeadline = nil; receiverProbeOwner = nil
            workerReceiverProbeFreshness = nil; workerReceiverProbeInterval = nil
            return nil
        }
        if let prior = receiverProbeOwner {
            let sameOwner = prior.id == value.id && prior.publishingGeneration == value.publishingGeneration &&
                prior.stage == value.stage && prior.bitRate == value.bitRate && prior.startedAt == value.startedAt
            if sameOwner {
                guard value.acceptedPayloadBytes >= prior.acceptedPayloadBytes,
                      value.leaseDeadline >= prior.leaseDeadline,
                      (value.lastAcceptedAt ?? 0) >= (prior.lastAcceptedAt ?? 0) else { return prior }
            } else {
                receiverProbeTracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: instant)
                workerReceiverProbeFreshness = nil; workerReceiverProbeInterval = nil
            }
        }
        acceptedProbeReadSequence = sequence
        receiverProbeOwner = value
        receiverProbeLeaseDeadline = instant + .seconds(value.leaseDeadline - now)
        return value
    }

    func measuredCandidateInput(_ state: PublishingQualitySession.Snapshot,
                                readCandidate: MeasuredCandidateReader) async -> PublishingCandidateAdmission? {
        guard let original = publishing else { return nil }
        let session = original.session, attempt = original.attempt, tap = original.context.tap
        let ownerEpoch = workerEpoch
        func ownsCurrent() -> Bool {
            guard let live = publishing else { return false }
            return !Task.isCancelled && workerEpoch == ownerEpoch && live.session === session && live.attempt == attempt &&
                diagnosticAttemptID == attempt && localState == .publishing &&
                activeRecordingID == original.context.id && current?.tap === tap &&
                live.session.snapshot.state == .publishing && live.session.snapshot.failure == nil
        }
        guard ownsCurrent(), state.attemptID == attempt, !state.isClosed, !state.isBusy else { return nil }
        let refreshSequence = nextProbeReadSequence()
        let nativeProbe = await original.probeObserver?.probeObservation()
        guard ownsCurrent() else { return nil }
        // This observes a real native lease even before candidate completion.
        // Receiver report timestamps remain anchored to the original response.
        guard acceptProbeObservation(nativeProbe, sequence: refreshSequence) != nil else { return nil }
        guard state.revision == 0, let settings = state.applied, let receipt = state.receipt,
              let acknowledgedAt = state.acknowledgedAt,
              let boundAuthority = candidateAuthority else { return nil }
        let candidateSequence = nextProbeReadSequence()
        let candidate = await readCandidate()
        guard ownsCurrent(), candidateAuthority === boundAuthority, let candidate else { return nil }
        guard let probe = acceptProbeObservation(candidate.probe, sequence: candidateSequence) else { return nil }
        // Read every mutable input only after the final await. Exact scope also
        // binds recording/tap observations, not just the publishing attempt.
        guard candidate.measurement.scope == publishing?.observations?.snapshot.scope,
              let pair = receiverProbeTracker.latestPair, let authority = candidateAuthority,
              authority.permits(pair.newer.end), authority.permits(pair.older.end) else { return nil }
        let applied = PublishingQualityTelemetry.Applied(attemptID: attempt, revision: 0,
            settings: settings, receipt: receipt, acknowledgedAt: acknowledgedAt)
        let id = candidate.measurement.id, permitsCandidate = candidate.permitsCurrentCandidate
        return .laboratoryIPv4(measurement: candidate.measurement, applied: applied,
            binding: candidate.binding, boundAt: candidate.boundAt, completedAt: candidate.completedAt,
            probe: probe, pair: pair, authority: authority, clock: .sample(),
            currentReceipt: { [weak session] in session?.snapshot.lastBitRateChange },
            candidateIsCurrent: { permitsCandidate(id) })
    }

    private func updateReceiverProbe(response: WorkerMediaStatusResponse, probe: PublishingProbeObservation?,
                                     receivedAt: ContinuousClock.Instant, requestDuration: Duration,
                                     requestStartedAtUptime: Double, responseReceivedAtUptime: Double,
                                     probeReadStartedAt: Double, probeReadFinishedAt: Double) {
        let now = ContinuousClock.now
        let nativeNow = ProcessInfo.processInfo.systemUptime
        guard let publishing, localState == .publishing, publishing.session.snapshot.state == .publishing,
              publishing.attempt == diagnosticAttemptID, activeRecordingID == publishing.context.id,
              current?.tap === publishing.context.tap, let probe, probe.isActive(at: nativeNow),
              probe.publishingGeneration == publishing.session.snapshot.transportClock?.publishingGeneration,
              let worker = commandState?.snapshot?.broadcast.selection?.workerId else {
            receiverProbeTracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false, at: now)
            receiverProbeLeaseDeadline = nil; receiverProbeOwner = nil
            workerReceiverProbeFreshness = nil; workerReceiverProbeInterval = nil; return
        }
        // ContinuousClock was sampled before uptime: conversion errs toward expiry.
        receiverProbeLeaseDeadline = now + .seconds(probe.leaseDeadline - nativeNow)
        receiverProbeOwner = probe
        let expected = WorkerReceiverProbeExpectation(gameId: response.status.gameId, generation: publishing.generation,
            workerId: worker, publishingAttemptId: publishing.attempt.uuidString.lowercased(),
            probeId: probe.id.uuidString.lowercased(), publishingGeneration: probe.publishingGeneration,
            bitRate: probe.bitRate, stage: probe.stage)
        let evidence = WorkerReceiverProbeFreshness(response: response, expected: expected,
            receivedAt: receivedAt, requestDuration: requestDuration)
        workerReceiverProbeInterval = receiverProbeTracker.observe(evidence, acceptedPayloadBytes: probe.acceptedPayloadBytes,
            senderActive: true, at: now)
        let fresh = evidence?.snapshotAgeUpperBound(at: now).map { $0 <= WorkerReceiverProbeTracker.maximumAge } == true &&
            (evidence?.snapshot.deliveredMessages == "0" || evidence?.lastDeliveryAgeUpperBound(at: now).map { $0 <= WorkerReceiverProbeTracker.maximumAge } == true)
        workerReceiverProbeFreshness = !receiverProbeTracker.isQuarantined && fresh ? evidence : nil
        #if DEBUG
        if workerReportAgeProofsEnabled {
            receiverProbeHistory.record(workerReceiverProbeInterval, accepted: probe, at: now,
                timing: .init(requestStartedAt: requestStartedAtUptime, responseReceivedAt: responseReceivedAtUptime,
                    nativeReadStartedAt: probeReadStartedAt, nativeReadFinishedAt: probeReadFinishedAt, evaluatedAt: nativeNow),
                quarantined: receiverProbeTracker.isQuarantined)
        }
        #endif
    }

    private func joinActiveMatch() async throws {
        guard var saved = setup else { throw CaptureControlError.noSetup }
        let client = try clientForSetup()
        let active = try await client.active(installationToken: saved.installationToken)
        try Task.checkCancellation()
        guard let match = active.snapshot, match.status == .active else { throw CaptureControlError.noActiveMatch }
        if saved.credential?.gameId != match.id {
            guard try pendingStore.load() == nil, saved.reports.isEmpty else { throw CaptureControlError.unresolved }
        }
        let joined = try await client.join(gameId: match.id, deviceId: saved.deviceId, role: .capture, installationToken: saved.installationToken)
        try Task.checkCancellation()
        guard joined.credential.gameId == match.id, joined.credential.deviceId == saved.deviceId, joined.credential.role == .capture else { throw CaptureControlError.invalidCredential }
        // Reload the mutable outbox after I/O: a local stop may have queued a report.
        saved.reports = setup?.reports ?? []
        saved.credential = joined.credential
        setup = saved
        try persist()
        try makeCoordinator()
        if let current { queueReport(current, status: .recording) }
    }
    private func makeCoordinator() throws {
        guard let saved = setup, let credential = saved.credential else { return }
        guard credential.deviceId == saved.deviceId, credential.role == .capture else { throw CaptureControlError.invalidCredential }
        coordinator = BroadcastCommandCoordinator(client: try clientForSetup(), credential: credential, installationToken: saved.installationToken, endpointScope: saved.endpointScope, store: pendingStore)
        connectedGameID = credential.gameId
    }
    private func clientForSetup() throws -> MatchHTTPClient {
        guard let setup else { throw CaptureControlError.noSetup }
        return clientFactory(try ScoringEndpoint(setup.endpoint))
    }
    private func check(_ context: CurrentCapture, _ attempt: UUID) throws {
        try Task.checkCancellation()
        guard current?.id == context.id, current?.tap === context.tap, epoch == attempt else { throw CaptureControlError.recordingStopped }
    }
    private func ingressConfiguration(for snapshot: VideoFrameObservationSnapshot?) -> LiveIngressObservationConfiguration? {
        guard let snapshot else { return nil }
        #if DEBUG && targetEnvironment(simulator)
        let limit = VideoObservationFixture.completedWindowLimit(environment: ProcessInfo.processInfo.environment)
        #else
        let limit = 8
        #endif
        return .init(scope: snapshot.scope, monotonicAnchor: snapshot.monotonicAnchor,
            windowDuration: snapshot.windowDuration, completedWindowLimit: limit, initialPhase: .startup)
    }

    private func clockObservation(_ clock: PublishingTransportClock?, scope: VideoFrameObservationScope?,
                                  isClosed: Bool) -> PublishingClockObservation? {
        guard let clock, let scope else { return nil }
        return PublishingClockObservation(scope: scope, transportClock: clock, isClosed: isClosed)
    }

    private func detachPublisher() {
        candidateAuthority?.revoke()
        if let publishing {
            publishing.context.tap.detach(publishing.session)
            let quality = qualityDriver; qualityDriver = nil; quality?.cancel()
            #if DEBUG
            cadenceReportAudit?.close()
            let cadenceData = try? cadenceReportAudit?.data()
            let cadenceWriter = cadenceReportFixtureWriter
            cadenceReportAudit = nil
            let transitions = transitionDriver; transitionDriver = nil; transitions?.cancel()
            let adaptiveProof = adaptiveProfileEvidence; adaptiveProfileEvidence = nil
            // Production fixture I/O defaults only on explicitly enabled simulators.
            // Tests may inject an in-memory writer to exercise this same joined boundary.
            let fixtureWriter = workerReportAgeProofsEnabled ? videoObservationFixtureWriter : nil
            // A final callback cannot establish capture detach or hide a stall.
            let captureDetachedAt = fixtureWriter == nil ? nil : ProcessInfo.processInfo.systemUptime
            let workerReportAgeProofs = workerReportAgeProofHistory.proofs
            let sourceIntervals = workerSourceIntervalHistory
            let probeWriter = workerReportAgeProofsEnabled ? receiverProbeFixtureWriter : nil
            let probeData = probeWriter == nil ? nil : publishing.observations.flatMap { try? receiverProbeHistory.data(scope: $0.snapshot.scope) }
            #endif
            publishing.session.cancel()
            if diagnosticAttemptID == publishing.attempt {
                let snapshot = publishing.session.snapshot
                ingressObservation = snapshot.ingressObservation
                publishingClockObservation = clockObservation(snapshot.transportClock,
                    scope: publishing.observations?.snapshot.scope, isClosed: true)
            }
            let session = publishing.session
            let observations = publishing.observations, attempt = publishing.attempt
            let id = UUID()
            teardownID = id
            publisherStopping = true
            publisherTeardown = Task { [self] in
                await quality?.stop()
                #if DEBUG
                await transitions?.stop()
                #endif
                await session.stop()
                #if DEBUG
                if let cadenceData, let cadenceWriter { await cadenceWriter(cadenceData) }
                if let probeData, let probeWriter { await probeWriter(probeData) }
                if let adaptiveProof {
                    adaptiveProof.close()
                    if let data = try? adaptiveProof.data() { await NativeProfileTransitionEvidence.persist(data) }
                }
                #endif
                // Drain completion owns closure, even when an old task can no longer
                // publish diagnostics. Normal stop changes epoch before this returns.
                let final = observations?.close()
                if teardownID == id {
                    if diagnosticAttemptID == attempt {
                        let snapshot = session.snapshot
                        videoObservation = final
                        ingressObservation = snapshot.ingressObservation
                        publishingClockObservation = clockObservation(snapshot.transportClock,
                            scope: final?.scope, isClosed: true)
                        #if DEBUG
                        if let final, let captureDetachedAt, let fixtureWriter {
                            await fixtureWriter(final, captureDetachedAt, workerReportAgeProofs, ingressObservation, publishingClockObservation, sourceIntervals)
                        }
                        #endif
                    }
                    publisherStopping = false
                    publisherTeardown = nil
                    teardownID = nil
                }
            }
        }
        publishing = nil; localState = .idle; sentSamples = 0; clearWorker()
    }
    private func clearWorker() {
        candidateAuthority?.revoke(); candidateAuthority = nil
        acceptedProbeReadSequence = nextProbeReadSequence()
        workerEpoch = UUID(); workerState = .unknown; workerFreshness = nil; workerDecodedVideoFreshness = nil; workerDecoderCadenceFreshness = nil
        workerSourceTracker.clear(); workerSourceInterval = nil
        if publishing == nil { workerDeliveryTracker.reset() } else { workerDeliveryTracker.unavailable() }
        workerDecoderDeliveryFreshness = nil
        if publishing == nil { receiverProbeTracker.reset() }
        else { receiverProbeTracker.observe(nil, acceptedPayloadBytes: 0, senderActive: false) }
        receiverProbeLeaseDeadline = nil; receiverProbeOwner = nil
        workerReceiverProbeFreshness = nil; workerReceiverProbeInterval = nil
        #if DEBUG
        workerReportAgeProofHistory.clear()
        workerSourceIntervalHistory = []
        if publishing == nil { receiverProbeHistory = ReceiverProbeFixtureHistory() }
        #endif
    }
    private func reserveStopOwnership(_ id: String) throws {
        guard var saved = setup else { throw CaptureControlError.noSetup }
        var ids = saved.stopRecordingIDs ?? []
        if !ids.contains(id) {
            guard ids.count < 64 else { throw CaptureControlError.unresolved }
            ids.append(id)
        }
        saved.stopRecordingIDs = ids
        setup = saved
        ownedRecordingIDs.insert(id)
        try persist()
    }
    private func setupClearStopOwnership() { setup?.stopRecordingIDs = [] }

    private func queueReport(_ context: CurrentCapture, status: RecordingStatus) {
        guard var saved = setup, let credential = saved.credential else { return }
        if let index = saved.reports.firstIndex(where: { $0.report.recordingId == context.id }) {
            if saved.reports[index].report.status == status { return }
            saved.reports[index].report.sequence += 1
            saved.reports[index].report.status = status
            saved.reports[index].delivered = false
        } else {
            saved.reports.append(PendingCaptureReport(credential: credential, report: RecordingReport(recordingId: context.id, sequence: 1, status: status, startedAt: context.startedAt), delivered: false))
        }
        setup = saved
        do { try persist() } catch { fail(error) }
    }
    private func flushReports() async throws {
        try persist()
        while let pending = setup?.reports.first(where: { !$0.delivered }) {
            // A live report is never replayed after local capture ends/relaunches.
            guard pending.report.status != .recording || current?.id == pending.report.recordingId else { throw CaptureControlError.recordingStopped }
            let response = try await clientForSetup().reportRecording(pending.report, credential: pending.credential)
            guard response.recording.gameId == pending.credential.gameId, response.recording.deviceId == pending.credential.deviceId,
                  response.recording.recordingId == pending.report.recordingId, response.recording.sequence == pending.report.sequence,
                  response.recording.status == pending.report.status, response.recording.startedAt == pending.report.startedAt else { throw MatchClientError.invalidResponse }
            if let index = setup?.reports.firstIndex(where: { $0.report == pending.report }) {
                if pending.report.status == .recording { setup?.reports[index].delivered = true }
                else { setup?.reports.remove(at: index) }
                try persist()
            }
            try Task.checkCancellation()
        }
    }
    private func persist() throws {
        guard let setup else { return }
        do { try storage.save(setup); needsStorageRetry = false }
        catch { needsStorageRetry = true; throw CaptureControlError.storage }
    }
    private func fail(_ error: Error) {
        candidateAuthority?.revoke()
        if error is CancellationError || error as? CaptureControlError == .recordingStopped { return }
        if localState == .starting { localState = .failed }
        if error as? CaptureControlError == .storage || error as? BroadcastCoordinatorError == .storageFailure {
            needsStorageRetry = true
            message = "Streaming state could not be saved. Retry before changing setup. Local recording is independent."
        } else if error as? CaptureControlError == .unresolved || commandState?.pending != nil {
            message = "Broadcast command is unresolved. Retry reconciliation before changing setup."
        } else if error as? CaptureControlError == .noActiveMatch {
            message = "No active match. Create or join a match in Score, then connect capture."
        } else if error as? CaptureControlError == .noSetup {
            message = "Set the server, installation token, worker and output before streaming."
        } else {
            message = "Streaming control failed. Check the server connection and retry. Local recording is independent."
        }
    }
    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}
