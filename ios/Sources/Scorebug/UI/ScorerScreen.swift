import ScorebugCore
import SwiftUI

/// A second phone scoring a match someone else is filming. Portrait, no camera:
/// two big team-colored halves, left and right as the court is filmed.
struct ScorerScreen: View {
    @ObservedObject var app: AppModel
    let session: MatchSession
    @ObservedObject var watch: PhoneWatchLink
    @StateObject private var board: ScoreboardModel
    @State private var confirmLeave = false

    init(app: AppModel, session: MatchSession, watch: PhoneWatchLink) {
        self.app = app
        self.session = session
        self.watch = watch
        // Take over once, right after joining; a relaunch never steals scoring back.
        _board = StateObject(wrappedValue: .make(session: session,
                                                 takeOverOnStart: Date().timeIntervalSince(session.startedAt) < 60))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                header
                if let message = board.problem {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.surface, in: Capsule())
                        .accessibilityIdentifier("scorer.problem")
                }
                if board.scoringElsewhere {
                    Button { board.takeOver() } label: { Label("Scoring on another device · Take over", systemImage: "hand.raised") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 48))
                        .accessibilityIdentifier("scorer.takeOver")
                }
                HStack(spacing: 10) {
                    ScoreHalf(board: board, side: .left)
                    ScoreHalf(board: board, side: .right)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    Button { board.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                        .disabled(!board.canUndo)
                        .accessibilityIdentifier("scorer.undo")
                    Button { board.swapSides() } label: { Label("Swap sides", systemImage: "arrow.left.arrow.right") }
                        .buttonStyle(BigButtonStyle(kind: .surface, height: 52))
                        .accessibilityIdentifier("scorer.swap")
                }
                Text("Left and right as the court is filmed.").font(.footnote).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            if board.isEnded {
                Theme.ground.opacity(0.7).ignoresSafeArea()
                MatchOverCard(board: board) { app.finish(lastSnapshot: board.snapshot) }.padding(20)
            } else if let prompt = board.flow.prompt {
                Theme.ground.opacity(0.7).ignoresSafeArea()
                SetPointCard(board: board, prompt: prompt).padding(20)
            } else if board.flow.asksToSwap {
                Theme.ground.opacity(0.7).ignoresSafeArea()
                SwapSidesCard(board: board).padding(20)
            }
        }
        .screenBackground()
        .confirmationDialog("Stop scoring on this phone?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Stop scoring", role: .destructive) { app.finish(lastSnapshot: nil) }
        } message: {
            Text("The match keeps going on the filming phone. You can join again with the same code.")
        }
        .task {
            OrientationLock.set(.portrait, rotateTo: .portrait)
            board.feedback = { Haptics.play($0) }
            board.onLayoutChange = { app.saveLayout($0) }
            board.onChange = { [weak watch, weak board] in watch?.push(board?.watchState) }
            watch.attach(board)
            await board.start()
            while !Task.isCancelled {
                await board.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { watch.attach(nil) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SET \(board.snapshot?.score.set ?? 1)").font(Theme.score(22)).kerning(1)
                Text(setsLine).font(.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if board.snapshot?.broadcast.desired == .running {
                HStack(spacing: 6) { Circle().fill(.white).frame(width: 7, height: 7); Text("LIVE").font(.footnote.weight(.bold)).kerning(1) }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.live, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Leave") { confirmLeave = true }
                .buttonStyle(OverlayButtonStyle())
                .accessibilityIdentifier("scorer.leave")
        }
        .padding(.top, 8)
    }

    private var setsLine: String {
        let left = board.team(on: .left), right = board.team(on: .right)
        return "Sets \(board.info(left)?.shortName ?? "") \(board.sets(left)) – \(board.sets(right)) \(board.info(right)?.shortName ?? "")"
    }
}
