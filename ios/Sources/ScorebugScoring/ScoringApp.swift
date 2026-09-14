import ScorebugCore
import SwiftUI

@main
struct ScoringApp: App {
    var body: some Scene { WindowGroup { NativeScoringView() } }
}

private struct NativeScoringView: View {
    @StateObject private var model = ScoringModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmEnd = false
    @State private var confirmSet = false
    @State private var confirmReconcile = false
    @State private var showOverride = false
    @State private var overrideWinner: MatchSide = .home
    @State private var overrideReason = ""

    var body: some View {
        NavigationStack {
            Form {
                if !model.connected { setupSection }
                if let match = model.snapshot { matchSection(match) }
                else if model.connected {
                    if model.hasJoinedMatch {
                        Section("Saved match") {
                            Text("Waiting for the current match state.")
                            Button("Retry match connection") { Task { await model.refresh() } }.disabled(model.busy)
                        }
                    } else { creationSection }
                }
                if model.busy { ProgressView("Checking with server…") }
                if model.needsStorageRetry {
                    Section {
                        Button("Retry saved settings") { Task { await model.wake() } }
                            .disabled(model.busy)
                            .accessibilityIdentifier("scoring.retryStorage")
                    }
                }
                if model.pending {
                    Section("Pending action") {
                        Text("Your last action is saved. The server must confirm it before another point can be sent.")
                        Button("Check again") { Task { await model.refresh() } }
                            .disabled(model.busy)
                        if model.state?.status == .reconciliationRequired {
                            Button("Reconcile expired action") { confirmReconcile = true }
                                .disabled(model.busy)
                        }
                    }
                }
                if let message = model.message {
                    Section { Text(message).accessibilityIdentifier("scoring.message") }
                }
            }
            .navigationTitle("Scorebug")
            .toolbar {
                if model.connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Server") { model.showSetup() }.disabled(!model.canChangeSetup)
                    }
                }
            }
            .confirmationDialog("End this set?", isPresented: $confirmSet, titleVisibility: .visible) {
                Button("End set") { Task { await model.send(.endSet(winner: nil, overrideReason: nil)) } }
                    .disabled(!model.canScore)
                    .accessibilityIdentifier("scoring.confirmSet")
            } message: { Text("The server checks the score against the match rules.") }
            .confirmationDialog("End this match?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End match", role: .destructive) { Task { await model.send(.endMatch(reason: "Match ended by scorer")) } }
                    .disabled(!model.canScore)
                    .accessibilityIdentifier("scoring.confirmEnd")
            } message: { Text("Scoring will close for all devices. This cannot be undone.") }
            .confirmationDialog("Reconcile the pending action?", isPresented: $confirmReconcile, titleVisibility: .visible) {
                Button("Check and reconcile") { Task { await model.discardExpired() } }.disabled(model.busy)
            } message: { Text("The app will check for a server receipt and only clear an unconfirmed action after it can no longer arrive.") }
            .sheet(isPresented: $showOverride) { overrideSheet }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.wake()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await model.refresh()
                }
            }
        }
    }
    private var setupSection: some View {
        Section {
            TextField("Server URL", text: $model.endpoint)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("scoring.endpoint")
            SecureField("Installation access token", text: $model.installationToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("scoring.token")
            Button("Connect") { Task { await model.connect() } }
                .accessibilityIdentifier("scoring.connect").disabled(!model.canChangeSetup)
        } header: { Text("Native scorer") }
        footer: { Text("Connect to your Scorebug server to create or join a match. Access tokens are stored in Keychain.") }
    }
    private var creationSection: some View {
        Group {
            Section("Teams") {
                TextField("Home team", text: $model.homeName).accessibilityIdentifier("scoring.homeName")
                TextField("Away team", text: $model.awayName).accessibilityIdentifier("scoring.awayName")
            }.disabled(model.busy || model.hasPendingCreation)
            Section("Rules") {
                Picker("Match", selection: $model.bestOf) { Text("Best of 3").tag(3); Text("Best of 5").tag(5) }
                Stepper("Set target: \(model.pointsToWin)", value: $model.pointsToWin, in: 1...99)
                Stepper("Deciding set: \(model.decidingPointsToWin)", value: $model.decidingPointsToWin, in: 1...99)
                Stepper("Win by: \(model.winBy)", value: $model.winBy, in: 1...10)
                Toggle("Point cap", isOn: $model.usesCap)
                if model.usesCap { Stepper("Cap: \(model.pointCap)", value: $model.pointCap, in: max(model.pointsToWin, model.decidingPointsToWin)...199) }
            }.disabled(model.busy || model.hasPendingCreation)
            Section {
                if model.hasPendingCreation {
                    Text("Retrying the saved match on \(model.endpoint)")
                    SecureField("Installation access token", text: $model.installationToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("scoring.repairToken")
                        .disabled(model.busy)
                }
                Button(model.hasPendingCreation ? "Retry saved match creation" : "Create match") { Task { await model.createMatch() } }
                    .accessibilityIdentifier("scoring.create")
                    .disabled(model.busy || model.homeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.awayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    @ViewBuilder
    private func matchSection(_ match: MatchSnapshot) -> some View {
        Section {
            Text("\(match.teams.home.name) vs \(match.teams.away.name)").font(.headline)
            Text("Set \(match.score.set) · Sets \(match.score.homeSets)–\(match.score.awaySets)")
            HStack(spacing: 16) {
                pointButton(side: .home, name: match.teams.home.name, score: match.score.home, color: .blue)
                pointButton(side: .away, name: match.teams.away.name, score: match.score.away, color: .red)
            }
            if match.status == .ended {
                Text("Match ended").accessibilityIdentifier("scoring.ended")
                Button("New match") { model.newMatch() }.disabled(!model.canChangeSetup)
                    .accessibilityIdentifier("scoring.newMatch")
            } else if model.ownsScoring {
                Text("You control scoring").foregroundStyle(.secondary)
                Button("Undo last action") { Task { await model.send(.undo) } }
                    .accessibilityIdentifier("scoring.undo").disabled(!model.canScore || !match.canUndo)
                Button("End set") { confirmSet = true }.disabled(!model.canScore)
                    .accessibilityIdentifier("scoring.endSet")
                Button("Override set result") { overrideReason = ""; showOverride = true }.disabled(!model.canScore)
                Button("End match", role: .destructive) { confirmEnd = true }.disabled(!model.canScore)
                    .accessibilityIdentifier("scoring.endMatch")
            } else {
                Text("Another device controls scoring. Taking over keeps the current score.")
                Button("Take over scoring") { Task { await model.send(.takeOver) } }
                    .accessibilityIdentifier("scoring.takeover").disabled(model.busy || model.pending)
            }
        } header: { Text("Match") }
    }
    private func pointButton(side: MatchSide, name: String, score: Int, color: Color) -> some View {
        Button { Task { await model.send(.awardPoint(side: side)) } } label: {
            VStack { Text(name).lineLimit(1).minimumScaleFactor(0.6); Text("\(score)").font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit() }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).tint(color).disabled(!model.canScore)
        .accessibilityIdentifier(side == .home ? "scoring.homePoint" : "scoring.awayPoint")
        .accessibilityLabel("Award point to \(name)").accessibilityValue("\(score)")
    }
    private var overrideSheet: some View {
        NavigationStack {
            Form {
                Picker("Winner", selection: $overrideWinner) { Text(model.snapshot?.teams.home.name ?? "Home").tag(MatchSide.home); Text(model.snapshot?.teams.away.name ?? "Away").tag(MatchSide.away) }
                TextField("Reason for override", text: $overrideReason, axis: .vertical)
                Text("The reason is saved with the result. A tied set still cannot end.")
                Button("Confirm override") {
                    showOverride = false
                    Task { await model.send(.endSet(winner: overrideWinner, overrideReason: overrideReason)) }
                }.disabled(overrideReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canScore)
            }.navigationTitle("Override set")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showOverride = false } } }
        }
    }
}
