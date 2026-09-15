import Combine
import Foundation
import ScorebugCore

/// One foreground owner of setup and the scoring outbox. The app owns polling;
/// this model owns, cancels and joins every operation before admitting another.
@MainActor
final class WatchScoringModel: ObservableObject {
    @Published private(set) var setupRecord: WatchSetupRecord?
    @Published private(set) var state: MatchCoordinatorState?
    @Published private(set) var offeredSetup: WatchPairingEnvelope?
    @Published private(set) var busy = false
    @Published private(set) var isActive = false
    @Published private(set) var message: String?

    private let setupCoordinator: WatchSetupCoordinator
    private let pendingStore: any PendingCommandStore
    private let scoringClientFactory: @MainActor @Sendable (WatchPairedSetup) throws -> any MatchScoringClient
    private let recoverUncertainSendImmediately: Bool
    private let onNotice: (WatchCompanionNotice) -> Void
    private let acknowledgmentHaptic: () -> Void
    private var coordinator: MatchCommandCoordinator?
    private var scoringSetup: WatchPairedSetup?
    private var operationTask: Task<Void, Never>?
    private var operationId: UUID?
    private var isPolling = false
    private var epoch = UUID()
    private var queuedOffer: WatchPairingEnvelope?
    private var describedOutcomeId: String?
    private var problemMessage = false
    private var lastNotice: WatchCompanionNotice?

    init(setupCoordinator: WatchSetupCoordinator, pendingStore: any PendingCommandStore,
         clientFactory: @escaping @Sendable (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         scoringClientFactory: (@MainActor @Sendable (WatchPairedSetup) throws -> any MatchScoringClient)? = nil,
         recoverUncertainSendImmediately: Bool = false,
         onNotice: @escaping (WatchCompanionNotice) -> Void = { _ in },
         acknowledgmentHaptic: @escaping () -> Void = {}) {
        self.setupCoordinator = setupCoordinator; self.pendingStore = pendingStore
        self.scoringClientFactory = scoringClientFactory ?? { paired in
            clientFactory(try ScoringEndpoint(paired.endpoint))
        }
        self.recoverUncertainSendImmediately = recoverUncertainSendImmediately
        self.onNotice = onNotice
        self.acknowledgmentHaptic = acknowledgmentHaptic
    }

    var snapshot: MatchSnapshot? { state?.snapshot }
    var phase: WatchCompanionPhase {
        if setupRecord?.paired != nil { return .paired }
        return setupRecord?.pending == nil ? .unpaired : .pending
    }
    var pending: Bool { state?.pending != nil }
    var ownsScoring: Bool {
        guard let credential = setupRecord?.paired?.credential, let snapshot else { return false }
        return snapshot.id == credential.gameId && snapshot.scorer.deviceId == credential.deviceId
    }
    var canScore: Bool { isActive && !busy && !pending && ownsScoring && snapshot?.status == .active }
    var canTakeOver: Bool {
        isActive && !busy && !pending && phase == .paired && !ownsScoring && snapshot?.status == .active
    }
    var canReplaceSetup: Bool {
        guard isActive, !busy, operationTask == nil, !pending, setupRecord != nil, setupRecord?.pending == nil else { return false }
        do { return try pendingStore.load() == nil } catch { return false }
    }

    func wake() async {
        // A second wake cannot reactivate the model while suspend is joining.
        guard !busy, operationTask == nil else { return }
        isActive = true
        lastNotice = nil // Each foreground wake advertises the persisted identity again.
        await run { token in
            let restored = try await self.setupCoordinator.restore()
            try self.check(token)
            try self.install(restored)
            try await self.recover(token)
        }
    }

    func suspend() async {
        isActive = false
        epoch = UUID()
        let task = operationTask, id = operationId
        task?.cancel()
        // Ignored transport cancellation is allowed to finish durable work, but
        // its old epoch cannot change UI, notices or haptics during suspension.
        await task?.value
        if operationId == id {
            operationTask = nil; operationId = nil; busy = false; isPolling = false
        }
    }

    func receive(_ envelope: WatchPairingEnvelope) async {
        guard (try? WatchCompanionCodec.encodeEnvelope(envelope)) != nil else {
            if isActive { message = "The iPhone setup offer is invalid." }
            return
        }
        // One latest value, with the same strict size bound as the OS bridge.
        queuedOffer = envelope
        if isActive && !busy { await consumeOffer() }
    }

    func acceptOfferedSetup(replacingCurrent: Bool = false) async {
        guard isActive, !busy, let offer = offeredSetup else { return }
        guard !pending else { message = "Reconcile the pending score before joining another match."; return }
        if phase == .paired && !replacingCurrent {
            message = "Choose Join new match to replace the current setup."; return
        }
        // Includes the coordinator's in-memory attempted command after a failed
        // initial save, as well as the durable outbox checked by Core.
        guard phase == .pending || canReplaceSetup else {
            message = "Scoring storage must be available and empty before changing setup."; return
        }
        await run { token in
            let result = try await self.setupCoordinator.accept(endpoint: offer.endpoint,
                offer: offer.offer, replacingCurrent: replacingCurrent)
            try self.check(token)
            try self.install(result)
            try await self.recoverScoring(token)
        }
    }

    func refresh() async {
        await run { token in
            let restored = try await self.setupCoordinator.restore()
            try self.check(token)
            try self.install(restored)
            try await self.recover(token)
        }
    }

    /// Foreground observation only. Pending work uses explicit refresh/recovery;
    /// healthy polling must not disable point or takeover controls.
    func poll() async {
        guard phase == .paired, !pending, let coordinator else { return }
        await run(passive: true) { token in
            let result = try await coordinator.refresh()
            try self.check(token)
            self.install(result)
        }
    }

    func send(_ operation: MatchOperation) async {
        guard isActive, !busy else { return }
        guard operation == .takeOver ? canTakeOver : canScore, let coordinator else {
            message = pending ? "Reconcile the pending action before scoring." : "Take over scoring before changing the score."
            return
        }
        let expectedSetup = scoringSetup
        await run(joiningPassivePoll: true) { token in
            let latest = await coordinator.state()
            try self.check(token)
            guard self.scoringSetup == expectedSetup, let credential = expectedSetup?.credential else {
                throw MatchCoordinatorError.scopeMismatch
            }
            self.install(latest)
            guard latest.pending == nil, let snapshot = latest.snapshot,
                  snapshot.id == credential.gameId, snapshot.status == .active,
                  operation == .takeOver ? snapshot.scorer.deviceId != credential.deviceId
                    : snapshot.scorer.deviceId == credential.deviceId else {
                throw MatchCoordinatorError.scoringNotAllowed
            }
            self.message = nil; self.problemMessage = false
            do {
                let result = try await coordinator.submit(operation)
                try self.check(token)
                self.install(result)
            } catch {
                try self.check(token)
                guard self.recoverUncertainSendImmediately,
                      WatchRoutedScoringClient.isRecoverableTransportFailure(error) else { throw error }
                let uncertain = await coordinator.state()
                try self.check(token)
                guard uncertain.pending != nil else { throw error }
                self.install(uncertain)
                // One receipt-first recovery within this same owned operation.
                // The coordinator alone may retry the exact durable command.
                let recovered = try await coordinator.recover()
                try self.check(token)
                self.install(recovered)
            }
        }
    }

    func discardExpiredScoring() async {
        guard let coordinator else { return }
        await run { token in
            let result = try await coordinator.discardExpired()
            try self.check(token)
            self.install(result)
            if result.pending == nil && result.outcome == nil {
                self.message = "Pending action reconciled. Check the score before continuing."
            }
        }
    }

    func discardExpiredPairing() async {
        await run { token in
            let result = try await self.setupCoordinator.discardExpired()
            try self.check(token)
            try self.install(result)
            // Never immediately reaccept an offer explicitly discarded as expired.
            if result.record?.pending == nil { self.offeredSetup = nil }
            try await self.recoverScoring(token)
        }
    }

    private func run(passive: Bool = false, joiningPassivePoll: Bool = false,
                     _ body: @escaping @MainActor (UUID) async throws -> Void) async {
        guard isActive, !busy else { return }
        let previous: Task<Void, Never>?
        if let operationTask {
            guard joiningPassivePoll, isPolling else { return }
            previous = operationTask
        } else { previous = nil }
        // Reserve admission before awaiting the poll. Only this one intent may
        // wait; every later action sees busy, and no new Core owner can start.
        busy = !passive; isPolling = passive
        let token = epoch, id = UUID()
        operationId = id
        previous?.cancel()
        let task = Task { @MainActor in
            do {
                // The replacement owns the old poll through terminal completion.
                // Suspend joins this task, which therefore joins the poll too.
                await previous?.value
                try self.check(token)
                try await body(token)
            }
            catch {
                guard self.current(token) else { return }
                let setup = await self.setupCoordinator.state()
                guard self.current(token) else { return }
                // This state contains only successfully committed credentials.
                do { try self.install(setup) } catch { /* Report the original failure below. */ }
                let scoring = await self.coordinator?.state()
                guard self.current(token) else { return }
                if let scoring { self.state = scoring }
                self.message = Self.explain(error); self.problemMessage = true
            }
        }
        operationTask = task
        await task.value
        guard operationId == id else { return }
        operationTask = nil; operationId = nil; busy = false; isPolling = false
        if isActive { await consumeOffer() }
    }

    private func current(_ token: UUID) -> Bool { isActive && epoch == token && !Task.isCancelled }
    private func check(_ token: UUID) throws { guard current(token) else { throw CancellationError() } }

    private func recover(_ token: UUID) async throws {
        if setupRecord?.pending != nil {
            let recovered = try await setupCoordinator.recover()
            try check(token)
            try install(recovered)
        }
        try await recoverScoring(token)
    }

    private func recoverScoring(_ token: UUID) async throws {
        guard let coordinator else { return }
        let recovered = try await coordinator.recover()
        try check(token)
        install(recovered)
    }

    private func install(_ setup: WatchSetupState) throws {
        setupRecord = setup.record
        if scoringSetup != setup.record?.paired {
            // Disable the old scorer before constructing a replacement. Keep
            // scoringSetup nil if construction fails so a later wake can retry.
            scoringSetup = nil
            state = nil; describedOutcomeId = nil; coordinator = nil
            if let paired = setup.record?.paired {
                let client = try scoringClientFactory(paired)
                coordinator = MatchCommandCoordinator(client: client,
                    credential: paired.credential, endpointScope: paired.scoringScope, store: pendingStore)
                scoringSetup = paired
            }
        }
        if let paired = setup.record?.paired, let offeredSetup,
           paired.pairingId == offeredSetup.offer.pairingId && paired.credential.gameId == offeredSetup.offer.gameId,
           (try? ScoringEndpoint(paired.endpoint).canonicalAddress) == (try? ScoringEndpoint(offeredSetup.endpoint).canonicalAddress) {
            self.offeredSetup = nil
        }
        if let record = setup.record {
            let notice = WatchCompanionNotice(deviceId: record.deviceId, phase: phase,
                gameId: record.paired?.credential.gameId ?? record.pending?.offer.gameId,
                pairingId: record.paired?.pairingId ?? record.pending?.offer.pairingId)
            if notice != lastNotice { lastNotice = notice; onNotice(notice) }
        }
    }

    private func install(_ value: MatchCoordinatorState) {
        state = value
        if let outcome = value.outcome, value.pending == nil, describedOutcomeId != outcome.commandId {
            describedOutcomeId = outcome.commandId; problemMessage = false
            if outcome.accepted {
                message = "Action accepted."
                acknowledgmentHaptic()
            } else {
                message = outcome.error == "set_tied" || outcome.error == "tied_set"
                    ? "Set is tied. Award another point before ending the set."
                    : "Action rejected. Check the current score and scorer before trying again."
            }
        } else if value.status == .reconciliationRequired {
            message = "The pending action needs review. Check the score, then reconcile."; problemMessage = true
        } else if value.pending == nil && problemMessage {
            message = nil; problemMessage = false
        }
    }

    private func consumeOffer() async {
        guard isActive, !busy, setupRecord != nil, let incoming = queuedOffer else { return }
        queuedOffer = nil
        guard setupRecord?.deviceId == incoming.offer.watchDeviceId else {
            message = "This setup offer is for another Watch."; return
        }
        if let paired = setupRecord?.paired, paired.pairingId == incoming.offer.pairingId,
           paired.credential.gameId == incoming.offer.gameId,
           (try? ScoringEndpoint(paired.endpoint).canonicalAddress) == (try? ScoringEndpoint(incoming.endpoint).canonicalAddress) { return }
        offeredSetup = incoming
        // Receiving setup never implies user acceptance, including first pairing.
    }

    private static func explain(_ error: Error) -> String {
        switch error {
        case WatchSetupError.storageFailure, MatchCoordinatorError.storageFailure:
            return "Could not save Watch data. Pending work is preserved. Unlock the Watch and retry."
        case WatchSetupError.pendingScoring, MatchCoordinatorError.pendingCommand:
            return "Reconcile the pending score before changing setup."
        case MatchCoordinatorError.scopeMismatch:
            return "Pending scoring belongs to another setup. Restore that setup before reconciling."
        case MatchCoordinatorError.scoringNotAllowed:
            return "Scoring authority changed. Check the current score and scorer before trying again."
        case MatchCoordinatorError.notExpired:
            return "The pending action is still recent. Retry receipt recovery before reconciling."
        case MatchClientError.http(status: 409, code: "pairing_expired"):
            return "Pairing expired. Reconcile pairing, then request a new offer on iPhone."
        case WatchSetupError.invalidOffer, WatchSetupError.invalidSetup, WatchSetupError.invalidResponse:
            return "Watch setup could not be verified. Check the iPhone setup and retry."
        case MatchClientError.unauthorized, MatchClientError.forbidden:
            return "Watch access was rejected. Check the paired match on iPhone."
        default:
            return "Could not confirm the update. Retry to recover the original action."
        }
    }
}
