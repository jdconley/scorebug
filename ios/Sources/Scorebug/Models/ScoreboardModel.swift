import Combine
import Foundation
import ScorebugCore

/// Live scoring for one match: tap a court half to score, undo, swap sides, and
/// the set-point → "Teams switching sides?" flow. Used by the filming screen,
/// the scorer screen and (through the phone) the Watch.
///
/// Every change goes through `MatchCommandCoordinator`, the durable one-command
/// outbox, so a point sent during a dropout is checked against the server before
/// it is ever sent again.
@MainActor final class ScoreboardModel: ObservableObject {
    enum Feedback: Equatable { case point, undo, setEnded, problem }

    @Published private(set) var snapshot: MatchSnapshot?
    @Published private(set) var layout: CourtLayout
    @Published private(set) var flow = SetPointFlow()
    @Published private(set) var sending = false
    /// A small, non-blocking line ("Can't reach the server…"). Never a modal.
    @Published private(set) var problem: String?

    let session: MatchSession
    var onLayoutChange: (CourtLayout) -> Void = { _ in }
    /// Fires after anything the Watch mirror shows changes.
    var onChange: () -> Void = {}
    var feedback: (Feedback) -> Void = { _ in }

    private let coordinator: MatchCommandCoordinator
    private var queue: [MatchOperation] = []
    private var draining = false
    private var takeOverOnStart: Bool
    private var started = false

    init(session: MatchSession, coordinator: MatchCommandCoordinator, takeOverOnStart: Bool = false) {
        self.session = session
        self.coordinator = coordinator
        self.layout = session.layout
        self.takeOverOnStart = takeOverOnStart
    }

    convenience init(session: MatchSession, client: any MatchScoringClient, pendingStore: any PendingCommandStore,
                     takeOverOnStart: Bool = false) {
        self.init(session: session,
                  coordinator: MatchCommandCoordinator(client: client, credential: session.credential,
                                                       endpointScope: session.endpointScope, store: pendingStore),
                  takeOverOnStart: takeOverOnStart)
    }

    // MARK: What the screens show

    var ownsScoring: Bool { snapshot.map { $0.scorer.deviceId == session.credential.deviceId } ?? false }
    var isActive: Bool { snapshot?.status == .active }
    var isEnded: Bool { snapshot?.status == .ended }
    var canScore: Bool { isActive && ownsScoring }
    var canUndo: Bool { canScore && (snapshot?.canUndo ?? false) }
    var scoringElsewhere: Bool { isActive && snapshot != nil && !ownsScoring }

    func team(on side: CourtSide) -> TeamSlot { layout.team(on: side) }
    func info(_ slot: TeamSlot) -> MatchTeam? { snapshot?.teams[slot] }
    func points(_ slot: TeamSlot) -> Int { snapshot?.score.points(slot) ?? 0 }
    func sets(_ slot: TeamSlot) -> Int { snapshot?.score.sets(slot) ?? 0 }

    // MARK: Lifecycle

    /// Loads the match and, for a phone that just joined through an invite, takes over scoring once.
    func start() async {
        guard !started else { await poll(); return }
        started = true
        await poll()
        if takeOverOnStart, isActive, !ownsScoring {
            takeOverOnStart = false
            enqueue(.takeOver)
        } else {
            takeOverOnStart = false
        }
    }

    /// Refreshes the score from the server (another phone or the Watch may have scored).
    /// Also finishes checking a change whose reply was lost.
    func poll() async {
        guard !draining else { return }
        do {
            apply(try await coordinator.recover())
            if problem != nil, !sending { problem = nil }
        } catch MatchCoordinatorError.busy {
            return
        } catch {
            report(error)
        }
    }

    // MARK: Scoring

    func tap(_ side: CourtSide) { point(layout.team(on: side)) }

    func point(_ team: TeamSlot) {
        guard canScore else { if scoringElsewhere { problem = "Another device is scoring. Tap Take over to score here." }; return }
        feedback(.point)
        enqueue(.awardPoint(side: team.side))
    }

    func undo() {
        guard canScore else { return }
        feedback(.undo)
        enqueue(.undo)
    }

    func takeOver() {
        guard scoringElsewhere else { return }
        enqueue(.takeOver)
    }

    func swapSides() {
        layout.swap()
        onLayoutChange(layout)
        onChange()
    }

    // MARK: Set point

    /// "End set" (or "End match" when this set decides it).
    func confirmSetEnd() {
        guard let prompt = flow.prompt, canScore else { return }
        flow.decline() // hide at once; a failure shows it again
        enqueue(.endSet(winner: nil, overrideReason: nil))
        if prompt.decidesMatch { enqueue(.endMatch(reason: "Match complete")) }
        onChange()
    }

    /// Keep playing: hide this set point until the score changes.
    func declineSetEnd() {
        flow.decline()
        onChange()
    }

    func undoFromPrompt() {
        flow.decline()
        undo()
        onChange()
    }

    func answerSwap(_ switching: Bool) {
        if switching { layout.swap(); onLayoutChange(layout) }
        flow.answerSwap()
        onChange()
    }

    /// Ends the match from the End button. Waits for the server so the caller can stop recording after.
    func endMatch(reason: String = "Ended by scorer") async {
        guard isActive else { return }
        if !ownsScoring { enqueue(.takeOver) }
        enqueue(.endMatch(reason: reason))
        await drain()
    }

    func handle(_ intent: WatchRemote.Intent) {
        switch intent {
        case .hello: onChange()
        case .point(let team): point(team)
        case .undo: undo()
        case .swapSides: swapSides()
        case .confirmSetEnd: confirmSetEnd()
        case .declineSetEnd: declineSetEnd()
        case .answerSwap(let switching): answerSwap(switching)
        }
    }

    // MARK: Sending

    private func enqueue(_ operation: MatchOperation) {
        queue.append(operation)
        Task { await drain() }
    }

    /// One command at a time, in tap order.
    func drain() async {
        guard !draining else { return }
        draining = true; sending = true
        onChange()
        defer { draining = false; sending = false; onChange() }
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            do {
                var state: MatchCoordinatorState
                do {
                    state = try await coordinator.submit(operation)
                } catch MatchCoordinatorError.pendingCommand {
                    // An earlier change is still unconfirmed: settle it, then send this one.
                    state = try await coordinator.recover()
                    apply(state)
                    guard state.pending == nil else { throw MatchCoordinatorError.pendingCommand }
                    state = try await coordinator.submit(operation)
                }
                apply(state)
                if let outcome = state.outcome, !outcome.accepted {
                    queue.removeAll()
                    rejected(outcome.error)
                } else {
                    problem = nil
                }
            } catch {
                queue.removeAll()
                report(error)
            }
        }
    }

    private func apply(_ state: MatchCoordinatorState) {
        if let incoming = state.snapshot {
            let previousSets = snapshot?.completedSets.count
            snapshot = incoming
            flow.observe(incoming)
            if let previousSets, incoming.completedSets.count > previousSets { feedback(.setEnded) }
        }
        if state.status == .reconciliationRequired {
            // Too old to resend safely. Drop it once the server proves it never arrived.
            problem = "A change may not have reached the server. Check the score."
            Task { [coordinator] in
                if let settled = try? await coordinator.discardExpired() { self.apply(settled) }
            }
        }
        onChange()
    }

    private func rejected(_ code: String?) {
        feedback(.problem)
        problem = FriendlyError.message(code: code, status: 409)
        if let snapshot, code == "set_not_won" || code == "tied_set" { flow.forgetDecline(snapshot) }
    }

    private func report(_ error: Error) {
        if case MatchCoordinatorError.scoringNotAllowed = error {
            problem = "Another device is scoring. Tap Take over to score here."
        } else if error is URLError || error as? MatchCoordinatorError == .pendingCommand {
            problem = "Can't reach the server. The last change will be checked and sent."
        } else {
            problem = FriendlyError.message(error)
        }
        feedback(.problem)
        onChange()
    }

    /// What the paired Watch shows.
    var watchState: WatchRemote.State? {
        guard let snapshot else { return nil }
        let note: String? = scoringElsewhere ? "Scoring on another device" : problem.map { _ in "Can't reach server" }
        return WatchRemote.State(snapshot: snapshot, layout: layout, flow: flow, isLive: isLiveForWatch,
                                 canScore: canScore, busy: sending, note: note)
    }

    /// Set by the filming screen while the broadcast runs.
    var isLiveForWatch = false { didSet { if oldValue != isLiveForWatch { onChange() } } }
}
