import ScorebugCore
import SwiftUI

/// Lifecycle and foreground polling belong to the app, not this view.
struct WatchScoringView: View {
    @ObservedObject var model: WatchScoringModel
    @State private var confirmingSet = false
    @State private var confirmingEnd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(phaseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.phase")
                    .accessibilityValue(model.phase.rawValue)
                if let match = model.snapshot {
                    Text("\(match.score.home)–\(match.score.away)")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .accessibilityLabel("Score")
                        .accessibilityValue("\(match.score.home)-\(match.score.away)")
                        .accessibilityIdentifier("watch.score")
                    HStack(alignment: .top, spacing: 8) {
                        pointButton(match.teams.home.name, side: .home)
                        pointButton(match.teams.away.name, side: .away)
                    }
                    Text("Set \(match.score.set) · Sets \(match.score.homeSets)–\(match.score.awaySets)")
                        .font(.caption).monospacedDigit()
                    if match.status == .ended {
                        Text("Match ended").font(.headline)
                    } else if !model.ownsScoring {
                        Button("Take over scoring") { Task { await model.send(.takeOver) } }
                            .disabled(!model.canTakeOver)
                            .accessibilityIdentifier("watch.takeover")
                    }
                    Button("Undo last action", systemImage: "arrow.uturn.backward") {
                        Task { await model.send(.undo) }
                    }
                    .disabled(!model.canScore || !match.canUndo)
                    .accessibilityIdentifier("watch.undo")
                    Button("End set") { confirmingSet = true }
                        .disabled(!model.canScore)
                        .accessibilityIdentifier("watch.endSet")
                    Button("End match", role: .destructive) { confirmingEnd = true }
                        .disabled(!model.canScore)
                        .accessibilityIdentifier("watch.endMatch")
                } else if model.phase == .unpaired {
                    Text("Open Scorebug on your iPhone to pair this Watch.")
                        .font(.callout).multilineTextAlignment(.center)
                }
                if model.pending {
                    Text("Score action pending").font(.headline)
                    Button("Reconcile scoring") { Task { await model.discardExpiredScoring() } }
                        .disabled(model.busy).accessibilityIdentifier("watch.reconcileScoring")
                }
                if model.phase == .pending {
                    Text("Pairing needs confirmation").font(.headline)
                    Button("Reconcile pairing") { Task { await model.discardExpiredPairing() } }
                        .disabled(model.busy).accessibilityIdentifier("watch.reconcilePairing")
                }
                if model.offeredSetup != nil && model.phase != .pending {
                    Button(model.phase == .paired ? "Join new match" : "Join offered match") {
                        Task { await model.acceptOfferedSetup(replacingCurrent: model.phase == .paired) }
                    }
                    .disabled(!model.canReplaceSetup)
                    .accessibilityIdentifier("watch.joinOffered")
                }
                if let message = model.message {
                    Text(message).font(.caption).multilineTextAlignment(.center)
                        .accessibilityIdentifier("watch.message")
                }
                Button(model.pending || model.phase == .pending ? "Retry confirmation" : "Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.busy || !model.isActive)
                .accessibilityIdentifier("watch.refresh")
                #if DEBUG
                .accessibilityValue(model.setupProvenanceAccessibilityValue)
                #endif
                if model.busy { ProgressView().accessibilityLabel("Confirming update") }
            }
            .padding(.horizontal, 4)
        }
        .confirmationDialog("End this set?", isPresented: $confirmingSet, titleVisibility: .visible) {
            Button("Confirm end set") { Task { await model.send(.endSet(winner: nil, overrideReason: nil)) } }
                .accessibilityIdentifier("watch.confirmSet")
        } message: {
            Text("The server checks the set score. A tied set cannot end.")
        }
        .confirmationDialog("End this match?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End match", role: .destructive) { Task { await model.send(.endMatch(reason: "Ended from Watch")) } }
                .accessibilityIdentifier("watch.confirmEnd")
        } message: {
            Text("This finishes the match for every device.")
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .unpaired: return "Watch not paired"
        case .pending: return "Pairing pending"
        case .paired: return model.ownsScoring ? "You are scoring" : "Connected to match"
        }
    }

    private func pointButton(_ name: String, side: MatchSide) -> some View {
        Button { Task { await model.send(.awardPoint(side: side)) } } label: {
            VStack(spacing: 4) {
                Text(name).font(.caption).lineLimit(2).minimumScaleFactor(0.8)
                Text("+1").font(.system(.title2, design: .rounded, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .disabled(!model.canScore)
        .accessibilityLabel("Point for \(name)")
        .accessibilityIdentifier(side == .home ? "watch.homePoint" : "watch.awayPoint")
    }
}
