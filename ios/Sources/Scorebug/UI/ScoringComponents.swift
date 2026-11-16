import ScorebugCore
import SwiftUI

extension ScoreboardModel {
    /// Production scoreboard: real HTTP client and the durable on-disk outbox.
    static func make(session: MatchSession, takeOverOnStart: Bool = false) -> ScoreboardModel {
        let endpoint = (try? ScoringEndpoint(session.endpoint)) ?? (try! ScoringEndpoint("http://localhost"))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ScoreboardModel(session: session, client: MatchHTTPClient(endpoint: endpoint),
                               pendingStore: JSONFilePendingCommandStore(url: directory.appendingPathComponent("pending-command.json")),
                               takeOverOnStart: takeOverOnStart)
    }
}

/// "CASCADE 18  SET 3  15 SUMMIT", ordered by court side.
struct CompactScore: View {
    @ObservedObject var board: ScoreboardModel
    var body: some View {
        let left = board.team(on: .left), right = board.team(on: .right)
        HStack(spacing: 14) {
            TeamChip(team: board.info(left), size: 22)
            Text("\(board.points(left))").font(Theme.score(36)).monospacedDigit()
            VStack(spacing: 0) {
                Text("SET \(board.snapshot?.score.set ?? 1)").font(Theme.score(15, weight: .semibold)).kerning(1)
                Text("\(board.sets(left))–\(board.sets(right))").font(Theme.score(15, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
            Text("\(board.points(right))").font(Theme.score(36)).monospacedDigit()
            TeamChip(team: board.info(right), size: 22, trailingBar: true)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("live.score")
    }
    private var accessibility: String {
        let left = board.team(on: .left), right = board.team(on: .right)
        return "\(board.info(left)?.name ?? "") \(board.points(left)), \(board.info(right)?.name ?? "") \(board.points(right)), set \(board.snapshot?.score.set ?? 1)"
    }
}

/// Set point reached: confirm, undo the last point, or keep playing.
struct SetPointCard: View {
    @ObservedObject var board: ScoreboardModel
    let prompt: SetPointPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SET \(prompt.set) · SET POINT REACHED").font(.footnote.weight(.semibold)).kerning(1)
                    .foregroundStyle(Theme.secondary)
                Text(prompt.title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                TeamChip(team: board.info(prompt.winner), size: 22)
                Text(prompt.scoreLine).font(Theme.score(40)).monospacedDigit()
                TeamChip(team: board.info(prompt.winner.other), size: 22, trailingBar: true, dim: true)
                Spacer(minLength: 0)
            }
            Text(prompt.detail).font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Undo last point") { board.undoFromPrompt() }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                    .accessibilityIdentifier("setPoint.undo")
                Button(prompt.confirmLabel) { board.confirmSetEnd() }
                    .buttonStyle(BigButtonStyle(height: 48))
                    .accessibilityIdentifier("setPoint.confirm")
            }
            Button("Keep playing") { board.declineSetEnd() }
                .font(.subheadline).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 36)
                .accessibilityIdentifier("setPoint.keepPlaying")
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// After a set ends: teams usually change ends, so the tap halves should too.
struct SwapSidesCard: View {
    @ObservedObject var board: ScoreboardModel
    var body: some View {
        let left = board.team(on: .left), right = board.team(on: .right)
        VStack(spacing: 16) {
            Text("Teams switching sides?").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 14) {
                TeamChip(team: board.info(right), size: 22)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.secondary)
                TeamChip(team: board.info(left), size: 22, trailingBar: true)
            }
            Text("Set \(board.snapshot?.score.set ?? 2) starts with \(board.info(right)?.shortName ?? "") on the left.")
                .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Keep sides") { board.answerSwap(false) }
                    .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                    .accessibilityIdentifier("swap.no")
                Button("Yes, switch") { board.answerSwap(true) }
                    .buttonStyle(BigButtonStyle(height: 48))
                    .accessibilityIdentifier("swap.yes")
            }
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Final result card shown when the match ends.
struct MatchOverCard: View {
    @ObservedObject var board: ScoreboardModel
    var savingVideo = false
    let done: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text(board.snapshot.map(SetPointFlow.isDecided) == true ? "Final" : "Match ended").font(.title3.weight(.bold))
            HStack(spacing: 18) {
                TeamChip(team: board.info(.team1), size: 26, dim: board.sets(.team1) < board.sets(.team2))
                Text("\(board.sets(.team1)) – \(board.sets(.team2))").font(Theme.score(44)).monospacedDigit()
                TeamChip(team: board.info(.team2), size: 26, trailingBar: true, dim: board.sets(.team2) < board.sets(.team1))
            }
            if let snapshot = board.snapshot, !snapshot.completedSets.isEmpty {
                Text(MatchSummary.setScores(snapshot)).font(.subheadline).foregroundStyle(Theme.muted)
            }
            if savingVideo {
                HStack(spacing: 8) { ProgressView(); Text("Saving the video…") }.font(.subheadline).foregroundStyle(Theme.muted)
            }
            Button("Done", action: done)
                .buttonStyle(BigButtonStyle(height: 48))
                .disabled(savingVideo)
                .accessibilityIdentifier("matchOver.done")
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}

/// Invite scorer: QR, short code and a share sheet for the join link.
struct InviteSheet: View {
    let session: MatchSession
    let access: TeamAccess?
    @StateObject private var model = InviteModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Another phone can score this match. Point its camera at this code, or type the code in Scorebug → Join with a code.")
                        .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    if let invite = model.invite {
                        QRCodeImage(text: invite.link)
                            .frame(width: 220, height: 220)
                            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        Text(invite.code).font(Theme.score(44)).kerning(6)
                            .textSelection(.enabled)
                            .accessibilityLabel("Code \(invite.code.map(String.init).joined(separator: " "))")
                            .accessibilityIdentifier("invite.code")
                        if let text = model.shareText, let url = URL(string: invite.link) {
                            ShareLink(item: url, subject: Text("Score our match"), message: Text(text)) {
                                Label("Share invite", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                        }
                        Text("Works until the match ends.").font(.footnote).foregroundStyle(Theme.secondary)
                    } else if let error = model.error {
                        Text(error).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
                        Button("Try again") { Task { await model.create(session: session, access: access) } }
                            .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                    } else {
                        ProgressView().padding(40)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .navigationTitle("Invite scorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.create(session: session, access: access) }
    }
}

/// One big team-colored half for the scorer screen.
struct ScoreHalf: View {
    @ObservedObject var board: ScoreboardModel
    let side: CourtSide
    var body: some View {
        let slot = board.team(on: side)
        let team = board.info(slot)
        Button { board.tap(side) } label: {
            VStack(spacing: 6) {
                Text(team?.shortName ?? "—").font(Theme.score(30)).lineLimit(1).minimumScaleFactor(0.6)
                Text("\(board.points(slot))").font(Theme.score(120)).monospacedDigit().minimumScaleFactor(0.5)
                Text("Sets \(board.sets(slot))").font(.subheadline.weight(.semibold)).opacity(0.85)
            }
            .foregroundStyle(Theme.onTeam(team?.color))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.teamColor(team?.color), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!board.canScore)
        .accessibilityLabel("Point to \(team?.name ?? "team")")
        .accessibilityValue("\(board.points(slot))")
        .accessibilityIdentifier("score.\(side.rawValue)")
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
