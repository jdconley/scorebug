import Combine
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

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
    @Published private(set) var sentSamples = 0
    /// One bounded current or latest closed attempt. Counts are local callback
    /// evidence; a starting snapshot establishes neither applied settings nor readiness.
    @Published private(set) var videoObservation: VideoFrameObservationSnapshot?
    private var diagnosticAttemptID: UUID?
    @Published private(set) var activeRecordingID: String?
    private var workerEpoch = UUID()
    private var workerFreshness: WorkerStatusFreshness?
    private var setup: SavedCaptureSetup?
    var watchSetupConnection: (endpoint: String, installationToken: String)? {
        guard !needsStorageRetry, let setup, !setup.installationToken.isEmpty else { return nil }
        return (setup.endpoint, setup.installationToken)
    }
    private var restored = false
    private var current: CurrentCapture?
    private var publishing: (context: CurrentCapture, session: PublishingSession, generation: Int, attempt: UUID, observations: VideoFrameObservationOwner?)?
    private var coordinator: BroadcastCommandCoordinator?
    private var action: Task<Void, Never>?
    private var actionID: UUID?
    private var stoppingTask: Task<Void, Never>?
    private var publisherTeardown: Task<Void, Never>?
    private var teardownID: UUID?
    @Published private var publisherStopping = false
    private var epoch = UUID()
    @Published private var controlBusy = false
    private var shouldStopOwnedBroadcast = false
    private var ownedRecordingIDs: Set<String> = []
    private let storage: any CaptureSetupStorage
    private let pendingStore: any PendingBroadcastStore
    private let clientFactory: (ScoringEndpoint) -> MatchHTTPClient
    private let publisherFactory: (URL, VideoFrameObservationOwner?) throws -> any MediaPublisher
    private let observationFactory: (VideoFrameObservationScope) throws -> VideoFrameObservationOwner

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scorebug", isDirectory: true)
        self.init(storage: CaptureKeychain(), pendingStore: JSONFilePendingBroadcastStore(url: directory.appendingPathComponent("pending-broadcast.json")))
    }
    init(storage: any CaptureSetupStorage, pendingStore: any PendingBroadcastStore,
         clientFactory: @escaping (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         publisherFactory: @escaping (URL, VideoFrameObservationOwner?) throws -> any MediaPublisher = { SRTMediaPublisher(url: $0, observations: $1) },
         observationFactory: @escaping (VideoFrameObservationScope) throws -> VideoFrameObservationOwner = { try VideoFrameObservationOwner(scope: $0) }) {
        self.storage = storage; self.pendingStore = pendingStore
        self.clientFactory = clientFactory; self.publisherFactory = publisherFactory
        self.observationFactory = observationFactory
    }
    var canStart: Bool { current != nil && !busy && !stopping && !publisherStopping && !controlBusy && localState != .publishing && !needsStorageRetry && commandState?.pending == nil }
    var canChangeSetup: Bool {
        guard !busy, !stopping, !publisherStopping, !controlBusy, publishing == nil, !needsStorageRetry else { return false }
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
        current = context
        activeRecordingID = context?.id
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
        guard !busy, !stopping, !publisherStopping, !controlBusy, publishing == nil, let context = current else { return }
        busy = true
        let attempt = UUID(); epoch = attempt; actionID = attempt
        diagnosticAttemptID = attempt; videoObservation = nil
        localState = .starting; message = nil; clearWorker()
        let task = Task { [self] in
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
                let access = try await client.publishAccess(recordingId: context.id, generation: broadcast.generation, credential: credential)
                try check(context, attempt)
                // Measurement starts after the earlier control-plane requests, but
                // includes encoder/transport startup. Revision 1 identifies the existing
                // fixed 1080p30 configuration; it does not assert that startup applied it.
                let scope = VideoFrameObservationScope(recordingID: context.id, matchID: credential.gameId,
                    broadcastGeneration: broadcast.generation, publishingAttemptID: attempt, appliedProfileRevision: 1)
                // Unavailable diagnostics must not fail publishing, archive or storage.
                let observations = try? observationFactory(scope)
                videoObservation = observations?.snapshot
                let session: PublishingSession
                do {
                    session = try PublishingSession(publisher: publisherFactory(access.publishUrl, observations))
                } catch {
                    videoObservation = observations?.close()
                    throw error
                }
                publishing = (context, session, broadcast.generation, attempt, observations)
                guard context.tap.attach(session, observations: observations) else { throw CaptureControlError.recordingStopped }
                try await session.start()
                try check(context, attempt)
                localState = .publishing
                shouldStopOwnedBroadcast = false
                message = "Sending camera media. Worker output is reported separately."
            } catch {
                if epoch == attempt { detachPublisher(); localState = .failed; shouldStopOwnedBroadcast = true; fail(error) }
                if let coordinator { commandState = await coordinator.state() }
            }
        }
        action = task
        await task.value
        if actionID == attempt { action = nil; actionID = nil; busy = false }
    }

    func stopStreaming() async {
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
        guard !busy, !controlBusy, let setup, setup.credential != nil else { return }
        controlBusy = true
        defer { controlBusy = false }
        do {
            try persist()
            if coordinator == nil { try makeCoordinator() }
            try await flushReports()
            guard let coordinator else { return }
            var state = try await coordinator.recover(activeRecordingId: shouldStopOwnedBroadcast ? nil : current?.id)
            commandState = state
            if shouldStopOwnedBroadcast {
                if state.pending != nil {
                    do { state = try await coordinator.discardExpired(); commandState = state }
                    catch BroadcastCoordinatorError.notExpired { return }
                }
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
            let requestStart = ContinuousClock.now
            let response = try await clientForSetup().workerStatus(credential: credential)
            guard observedEpoch == workerEpoch else { return }
            guard response.status.gameId == credential.gameId, response.status.generation == commandState?.snapshot?.broadcast.generation,
                  response.status.workerId == commandState?.snapshot?.broadcast.selection?.workerId else { clearWorker(); return }
            let received = ContinuousClock.now
            workerFreshness = WorkerStatusFreshness(response: response, receivedAt: received, requestDuration: requestStart.duration(to: received))
            workerState = workerFreshness?.isFresh() == true ? response.status.state : .stale
        } catch {
            clearWorker()
            if publishing != nil { detachPublisher(); localState = .failed; shouldStopOwnedBroadcast = true }
            if let coordinator { commandState = await coordinator.state() }
            fail(error)
        }
    }

    func pollLocalHealth() {
        if workerFreshness?.isFresh() == false { workerState = .stale; workerFreshness = nil }
        guard let publishing else { return }
        videoObservation = publishing.observations?.poll()
        let snapshot = publishing.session.snapshot
        sentSamples = snapshot.sentSamples
        if snapshot.failure != nil || snapshot.state == .stopped {
            detachPublisher(); shouldStopOwnedBroadcast = true
            localState = .failed
            message = "Camera publishing stopped. Your local recording continues. Retry streaming when the connection is ready."
        }
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
    private func detachPublisher() {
        if let publishing {
            publishing.context.tap.detach(publishing.session)
            #if DEBUG && targetEnvironment(simulator)
            // Qualification boundary only: the final callback is not evidence of
            // detach, because treating it as one could hide a capture stall.
            let captureDetachedAt = VideoObservationFixture.requested(environment: ProcessInfo.processInfo.environment)
                ? ProcessInfo.processInfo.systemUptime : nil
            #endif
            publishing.session.cancel()
            let session = publishing.session
            let observations = publishing.observations, attempt = publishing.attempt
            let id = UUID()
            teardownID = id
            publisherStopping = true
            publisherTeardown = Task { [self] in
                await session.stop()
                // Drain completion owns closure, even when an old task can no longer
                // publish diagnostics. Normal stop changes epoch before this returns.
                let final = observations?.close()
                if teardownID == id {
                    if diagnosticAttemptID == attempt {
                        videoObservation = final
                        #if DEBUG && targetEnvironment(simulator)
                        if let final, let captureDetachedAt {
                            await VideoObservationFixture.writeClosed(final, captureDetachedAt: captureDetachedAt)
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
    private func clearWorker() { workerEpoch = UUID(); workerState = .unknown; workerFreshness = nil }
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
