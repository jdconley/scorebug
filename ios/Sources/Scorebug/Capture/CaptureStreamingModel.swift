import Combine
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming

/// Streams the current recording over SRT with a simple quality ladder.
/// The local recording never depends on this model: stream failures, quality
/// changes and reconnects only touch the publishing attempt attached to the tap.
@MainActor final class CaptureStreamingModel: ObservableObject {
    enum LocalState: String { case idle, starting, publishing, failed }
    /// What the Film screen shows.
    enum Status: Equatable { case off, recordingOnly, starting, live, reconnecting }
    static let publishingHealthInterval: Duration = .milliseconds(500)

    @Published var endpoint = "http://localhost:18787"
    @Published var installationToken = ""
    @Published var workerId = "local-worker"
    @Published var outputId = "local-output"
    @Published private(set) var localState: LocalState = .idle
    @Published private(set) var message: String?
    @Published private(set) var connectedGameID: String?
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    /// Live stream rung while publishing; nil otherwise.
    @Published private(set) var streamQuality: QualityLadder.Rung?
    private(set) var needsStorageRetry = false {
        willSet { if newValue != needsStorageRetry { objectWillChange.send() } }
    }
    private(set) var commandState: BroadcastCoordinatorState? {
        willSet { if newValue != commandState { objectWillChange.send() } }
    }
    @Published private(set) var activeRecordingID: String?

    private var setup: SavedCaptureSetup?
    var watchSetupConnection: (endpoint: String, installationToken: String)? {
        guard !needsStorageRetry, let setup, !setup.installationToken.isEmpty else { return nil }
        return (setup.endpoint, setup.installationToken)
    }
    private var restored = false
    // Transient sheet state only; never changes or clears the saved connection.
    var isSetupPresented = false
    private var current: CurrentCapture?
    private struct Publishing {
        let context: CurrentCapture
        let session: PublishingSession
        let generation: Int
        let attempt: UUID
    }
    private var publishing: Publishing?
    private var coordinator: BroadcastCommandCoordinator?
    var controlPollInterval: Duration { .seconds(2) }

    /// One ladder per recording; it survives reconnects of that recording.
    private var ladder: (recordingID: String, policy: QualityLadder)?
    private var profileChange: Task<Void, Never>?

    private var action: Task<Void, Never>?
    private var actionID: UUID?
    private var stoppingTask: Task<Void, Never>?
    private var publisherTeardown: Task<Void, Never>?
    private var teardownID: UUID?
    @Published private var publisherStopping = false
    private var epoch = UUID()
    private var controlBusy = false {
        // Only the setup sheet displays whether polling temporarily locks its fields.
        willSet { if newValue != controlBusy && isSetupPresented { objectWillChange.send() } }
    }
    private struct Reconnect {
        let id = UUID()
        let context: CurrentCapture
        let gameID: String
        let generation: Int
        let notBefore: Double
    }
    @Published private var reconnect: Reconnect?
    private var reconnectFailures = 0
    private var requestedStart: CurrentCapture?
    private var shouldStopOwnedBroadcast = false
    private var ownedRecordingIDs: Set<String> = []
    private let storage: any CaptureSetupStorage
    private let pendingStore: any PendingBroadcastStore
    private let clientFactory: (ScoringEndpoint) -> MatchHTTPClient
    private let publisherFactory: (URL, PublishingVideoProfile) throws -> any MediaPublisher
    private let thermalReader: () -> QualityLadder.Thermal
    private let clock: () -> Double
    private let healthCheckInterval: Duration

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scorebug", isDirectory: true)
        self.init(storage: CaptureKeychain(), pendingStore: JSONFilePendingBroadcastStore(url: directory.appendingPathComponent("pending-broadcast.json")))
    }
    init(storage: any CaptureSetupStorage, pendingStore: any PendingBroadcastStore,
         clientFactory: @escaping (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         publisherFactory: @escaping (URL, PublishingVideoProfile) throws -> any MediaPublisher = {
             SRTStreamPublisher(url: $0, profile: $1)
         },
         thermalReader: @escaping () -> QualityLadder.Thermal = { QualityLadder.Thermal(ProcessInfo.processInfo.thermalState) },
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         healthCheckInterval: Duration = CaptureStreamingModel.publishingHealthInterval) {
        self.storage = storage; self.pendingStore = pendingStore; self.healthCheckInterval = healthCheckInterval
        self.clientFactory = clientFactory; self.publisherFactory = publisherFactory
        self.thermalReader = thermalReader; self.clock = clock
    }

    var isReconnecting: Bool { reconnect != nil }
    var canStopStreaming: Bool { localState == .publishing || localState == .starting || isReconnecting }
    var canStart: Bool { current != nil && !busy && !stopping && !publisherStopping && requestedStart == nil && localState != .publishing && !needsStorageRetry && commandState?.pending == nil }
    var canChangeSetup: Bool {
        guard !busy, !stopping, !publisherStopping, !controlBusy, requestedStart == nil, publishing == nil, !needsStorageRetry else { return false }
        do { return try pendingStore.load() == nil && (setup?.reports.isEmpty ?? true) && (setup?.stopRecordingIDs?.isEmpty ?? true) } catch { return false }
    }
    var status: Status {
        if isReconnecting { return .reconnecting }
        switch localState {
        case .publishing: return .live
        case .starting: return .starting
        case .idle, .failed: return current == nil ? .off : .recordingOnly
        }
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
        } catch { needsStorageRetry = true; message = "Streaming setup could not be restored. Retry to read the saved connection. Recording is not affected." }
    }

    /// Invoked in the same MainActor turn that clears FilmModel's context, before
    /// archive drain, storage, HTTP or encoder awaits. Detach/cancel is immediate.
    func captureChanged(_ context: CurrentCapture?, terminalStatus: RecordingStatus? = .stopped) {
        let previous = current
        if context?.id != previous?.id || context?.tap !== previous?.tap { cancelReconnect() }
        if let requestedStart, context?.id != requestedStart.id || context?.tap !== requestedStart.tap {
            self.requestedStart = nil
            localState = .idle
            message = "Streaming start canceled because the recording changed."
        }
        current = context
        activeRecordingID = context?.id
        if context?.id != ladder?.recordingID { ladder = nil }
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
        if reconnect?.context.tap === context.tap { cancelReconnect() }
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
                coordinator = nil; connectedGameID = nil; commandState = nil
            }
            try persist()
            busy = true
            defer { busy = false }
            try await joinActiveMatch()
            message = "Connected. Start recording, then go live."
        } catch { fail(error) }
    }

    func startStreaming() async {
        cancelReconnect()
        await beginStreaming()?.value
    }

    /// Called synchronously by the button so a poll cannot steal an accepted tap
    /// before an unstructured Task reaches the start guard. Only one intent exists.
    func requestStartStreaming() {
        guard canStart, let context = current else { return }
        cancelReconnect()
        if controlBusy {
            requestedStart = context
            localState = .starting
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
            message = "Streaming could not start while a previous request is unresolved. Retry, then go live again."
            return
        }
        _ = beginStreaming()
    }

    private func beginStreaming(reconnecting: Reconnect? = nil) -> Task<Void, Never>? {
        guard !busy, !stopping, !publisherStopping, !controlBusy, requestedStart == nil, publishing == nil, let context = current else { return nil }
        busy = true
        let attempt = UUID(); epoch = attempt; actionID = attempt
        if reconnecting == nil { localState = .starting; message = nil }
        let task = Task { [self] in
            defer { if actionID == attempt { action = nil; actionID = nil; busy = false } }
            do {
                await restore()
                try check(context, attempt)
                if reconnecting != nil, coordinator == nil { throw CaptureControlError.selectionChanged }
                if coordinator == nil { try await joinActiveMatch(); try check(context, attempt) }
                guard let setup, let credential = setup.credential, let coordinator else { throw CaptureControlError.noSetup }
                // A stop may have yielded to a running control poll or failed offline.
                // Resolve that intent before recovery can replay a start.
                if shouldStopOwnedBroadcast {
                    let stopped = try await coordinator.recover(activeRecordingId: nil)
                    try check(context, attempt)
                    commandState = stopped
                    commandState = try await reconcileOwnedStop(stopped, coordinator: coordinator)
                    try check(context, attempt)
                    guard !shouldStopOwnedBroadcast else { throw CaptureControlError.unresolved }
                }
                try reserveStopOwnership(context.id)
                queueReport(context, status: .recording)
                try await flushReports()
                try check(context, attempt)
                var state = try await coordinator.recover(activeRecordingId: context.id)
                try check(context, attempt)
                commandState = state
                guard state.pending == nil else { throw CaptureControlError.unresolved }
                let selection = BroadcastSelection(workerId: setup.workerId, outputId: setup.outputId, captureDeviceId: setup.deviceId, recordingId: context.id)
                if let reconnecting {
                    guard reconnect?.id == reconnecting.id, credential.gameId == reconnecting.gameID,
                          state.snapshot?.broadcast.desired == .running,
                          state.snapshot?.broadcast.generation == reconnecting.generation,
                          state.snapshot?.broadcast.selection == selection else { throw CaptureControlError.selectionChanged }
                }
                if state.snapshot?.broadcast.desired != .running || state.snapshot?.broadcast.selection != selection {
                    state = try await coordinator.submit(.start(selection: selection), activeRecordingId: context.id)
                    try check(context, attempt)
                    commandState = state
                    guard state.outcome?.accepted == true else { throw CaptureControlError.rejected }
                }
                guard let broadcast = state.snapshot?.broadcast, broadcast.desired == .running, broadcast.selection == selection else { throw CaptureControlError.selectionChanged }
                let access = try await clientForSetup().publishAccess(recordingId: context.id, generation: broadcast.generation,
                    publishingAttemptId: attempt, credential: credential)
                try check(context, attempt)
                var policy = ladder?.recordingID == context.id ? ladder!.policy
                    : QualityLadder(maximum: .fitting(height: context.profile.height))
                if reconnecting != nil { policy.connectionLost(at: clock()) }
                ladder = (context.id, policy)
                let profile = PublishingVideoProfile(policy.current)
                let session = try PublishingSession(publisher: publisherFactory(access.publishUrl, profile), profile: profile,
                    maxBytes: 12 * 1024 * 1024 * context.profile.captureQueueScale, healthCheckInterval: healthCheckInterval)
                publishing = Publishing(context: context, session: session, generation: broadcast.generation, attempt: attempt)
                guard context.tap.attach(session) else { throw CaptureControlError.recordingStopped }
                try await session.start()
                try check(context, attempt)
                localState = .publishing
                streamQuality = policy.current
                reconnect = nil; reconnectFailures = 0
                shouldStopOwnedBroadcast = false
                message = nil
            } catch {
                if epoch == attempt {
                    detachPublisher()
                    if let reconnecting, reconnect?.id == reconnecting.id,
                       Self.isTransientControlFailure(error) || error is PublishingSessionError {
                        scheduleReconnect(context: reconnecting.context, gameID: reconnecting.gameID,
                            generation: reconnecting.generation)
                    } else {
                        localState = .failed
                        cancelReconnect(); shouldStopOwnedBroadcast = reconnecting == nil; fail(error)
                    }
                }
                if let coordinator { commandState = await coordinator.state() }
            }
        }
        action = task
        return task
    }

    func stopStreaming() async {
        cancelReconnect()
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
    /// camera health or the ladder, which use pollLocalHealth().
    func pollBackgroundControl() async {
        await restore()
        // Keep the setup form editable while it is open and nothing is pending.
        if isSetupPresented && current == nil && canChangeSetup { return }
        await pollControl()
    }

    func pollControl() async {
        if needsStorageRetry && setup == nil { restored = false }
        await restore()
        // Defer the owned broadcast stop until publisher finish settles.
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
            if message == Self.serverUnreachableMessage { message = nil }
            if shouldStopOwnedBroadcast {
                state = try await reconcileOwnedStop(state, coordinator: coordinator)
                guard !publisherStopping else { return }
                if shouldStopOwnedBroadcast && state.pending != nil { return }
            }
            let broadcast = state.snapshot?.broadcast
            let generation = publishing?.generation ?? reconnect?.generation
            let recordingID = publishing?.context.id ?? reconnect?.context.id
            if let generation, let recordingID,
               broadcast?.desired != .running || broadcast?.generation != generation ||
               broadcast?.selection?.recordingId != recordingID || broadcast?.selection?.captureDeviceId != setup.deviceId {
                cancelReconnect()
                detachPublisher()
                message = "The broadcast was stopped or changed elsewhere. Recording continues on this device."
            }
        } catch {
            controlFailed = true
            if let coordinator { commandState = await coordinator.state() }
            handlePollingFailure(error)
        }
    }

    /// Keep stop ownership until recovery proves the owned selection is gone.
    /// Both maintenance and replacement startup must honor the same intent.
    private func reconcileOwnedStop(_ recovered: BroadcastCoordinatorState,
                                    coordinator: BroadcastCommandCoordinator) async throws -> BroadcastCoordinatorState {
        guard shouldStopOwnedBroadcast, let setup else { return recovered }
        var state = recovered
        if state.pending != nil {
            do { state = try await coordinator.discardExpired(); commandState = state }
            catch BroadcastCoordinatorError.notExpired { return state }
        }
        guard !publisherStopping else { return state }
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
            self.setup?.stopRecordingIDs = []
            try persist()
            shouldStopOwnedBroadcast = false
        }
        return state
    }

    /// Local tick (every 500 ms): feeds SRT sender stats and thermal state to the
    /// ladder, applies rung changes, and drives reconnects. No network I/O.
    func pollLocalHealth() {
        if let retry = reconnect, publishing == nil {
            if clock() >= retry.notBefore, !busy, !stopping, !publisherStopping, !controlBusy, !needsStorageRetry {
                _ = beginStreaming(reconnecting: retry)
            }
            return
        }
        guard let publishing, localState == .publishing else { return }
        let snapshot = publishing.session.snapshot
        if snapshot.failure != nil || snapshot.state == .stopped || snapshot.state == .failed {
            let gameID = setup?.credential?.gameId
            detachPublisher()
            if let gameID, current?.tap === publishing.context.tap, !stopping {
                scheduleReconnect(context: publishing.context, gameID: gameID, generation: publishing.generation)
            } else {
                localState = .failed
                cancelReconnect(); shouldStopOwnedBroadcast = true
                message = "Streaming stopped. Your recording continues on this device."
            }
            return
        }
        guard var entry = ladder, entry.recordingID == publishing.context.id,
              let stats = snapshot.transportStatistics else { return }
        let sample = QualityLadder.Sample(time: stats.sampledAt, senderBufferMilliseconds: stats.senderBufferMilliseconds,
            sentPackets: stats.sentPackets, retransmittedPackets: stats.retransmittedPackets, droppedPackets: stats.droppedPackets)
        // Hold the policy still while an encoder swap is in flight.
        guard profileChange == nil else { return }
        guard let rung = entry.policy.observe(sample, thermal: thermalReader()) else { ladder = entry; return }
        ladder = entry
        let session = publishing.session, attempt = publishing.attempt
        profileChange = Task { [weak self] in
            // A failure ends the session; the next tick reconnects.
            let applied = (try? await session.setVideoProfile(PublishingVideoProfile(rung))) != nil
            guard let self else { return }
            self.profileChange = nil
            if applied, self.publishing?.attempt == attempt { self.streamQuality = rung }
        }
    }

    private func cancelReconnect() {
        reconnect = nil; reconnectFailures = 0
    }
    private func scheduleReconnect(context: CurrentCapture, gameID: String, generation: Int) {
        reconnectFailures += 1
        reconnect = .init(context: context, gameID: gameID, generation: generation,
            notBefore: clock() + StreamReconnectBackoff.delay(afterFailures: reconnectFailures))
        localState = .idle
        shouldStopOwnedBroadcast = false
        message = nil
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
        profileChange?.cancel(); profileChange = nil
        streamQuality = nil
        if let publishing {
            publishing.context.tap.detach(publishing.session)
            publishing.session.cancel()
            let session = publishing.session
            let id = UUID()
            teardownID = id
            publisherStopping = true
            publisherTeardown = Task { [self] in
                await session.stop()
                if teardownID == id {
                    publisherStopping = false
                    publisherTeardown = nil
                    teardownID = nil
                }
            }
        }
        publishing = nil; localState = .idle
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
    private static let serverUnreachableMessage = "Can't reach the server. Streaming continues; retrying automatically."

    /// Control-plane availability is independent of the SRT media connection.
    /// Never resurrect starts or explicit stops.
    private func handlePollingFailure(_ error: Error) {
        if reconnect != nil {
            if Self.isTransientControlFailure(error) { return }
            cancelReconnect()
        }
        if let publishing, !shouldStopOwnedBroadcast, !publisherStopping,
           publishing.session.snapshot.state == .publishing, Self.isTransientControlFailure(error) {
            message = Self.serverUnreachableMessage
            return
        }
        if publishing != nil { detachPublisher(); localState = .failed; shouldStopOwnedBroadcast = true }
        fail(error)
    }

    private static func isTransientControlFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed:
                return true
            default: return false
            }
        }
        if case let MatchClientError.http(status, _) = error {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    private func fail(_ error: Error) {
        if error is CancellationError || error as? CaptureControlError == .recordingStopped { return }
        if localState == .starting { localState = .failed }
        if error as? CaptureControlError == .storage || error as? BroadcastCoordinatorError == .storageFailure {
            needsStorageRetry = true
            message = "Streaming state could not be saved. Retry before changing setup. Recording is not affected."
        } else if error as? CaptureControlError == .unresolved || commandState?.pending != nil {
            message = "A previous streaming request is unresolved. Retry before changing setup."
        } else if error as? CaptureControlError == .noActiveMatch {
            message = "No active match. Create or join a match in Score, then connect streaming."
        } else if error as? CaptureControlError == .noSetup {
            message = "Open Setup and enter the server and installation token before streaming."
        } else {
            message = "Couldn't start streaming. Check the server connection and retry. Recording is not affected."
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

extension PublishingVideoProfile {
    init(_ rung: QualityLadder.Rung) {
        switch rung {
        case .p360: self = .low360
        case .p540: self = .sd540
        case .p720: self = .hd720
        case .p1080: self = .hd1080
        }
    }
}

extension QualityLadder.Thermal {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}
