import ScorebugCore
import SwiftUI
import UIKit

/// Filming + scoring, landscape. Tap the left or right half of the picture to give
/// the team on that side a point.
struct LiveScreen: View {
    @ObservedObject var app: AppModel
    let session: MatchSession
    @ObservedObject var watch: PhoneWatchLink
    @StateObject private var live: LiveModel
    @State private var confirmEnd = false
    @State private var inviting = false
    @State private var savingVideo = false

    init(app: AppModel, session: MatchSession, film: FilmModel, streaming: CaptureStreamingModel, watch: PhoneWatchLink) {
        self.app = app
        self.session = session
        self.watch = watch
        let recordIn4K = app.preferences.lastDraft?.recordIn4K ?? false
        let preferences = app.preferences
        _live = StateObject(wrappedValue: LiveModel(session: session, access: app.access(teamId: session.teamId), scoreboard: .make(session: session),
                                                    film: film, streaming: streaming, preferences: preferences,
                                                    recordIn4K: recordIn4K))
    }

    private var board: ScoreboardModel { live.scoreboard }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraLayer(film: live.film)
                tapHalves(geo.size)
                overlayControls
                modal
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .confirmationDialog("End the match?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End match", role: .destructive) { Task { await end(endMatch: true) } }
        } message: {
            Text("Stops recording and the stream. The score is saved as it stands.")
        }
        .sheet(isPresented: $inviting) { InviteSheet(session: session, access: app.access(teamId: session.teamId)) }
        .task {
            OrientationLock.set(.landscape, rotateTo: .landscapeRight)
            board.feedback = { Haptics.play($0) }
            board.onLayoutChange = { app.saveLayout($0) }
            board.onChange = { [weak watch, weak board] in watch?.push(board?.watchState) }
            watch.attach(board)
            await board.start()
            await live.begin()
            while !Task.isCancelled {
                board.isLiveForWatch = live.isLive
                live.noteRecording()
                await board.poll()
                if board.isEnded, !live.finishing { await end(endMatch: false) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { watch.attach(nil) }
    }

    // MARK: Tap to score

    private func tapHalves(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(CourtSide.allCases, id: \.self) { side in
                let slot = board.team(on: side)
                Button { board.tap(side) } label: {
                    ZStack(alignment: side == .left ? .bottomLeading : .bottomTrailing) {
                        Color.clear
                        // A thin team-colored edge so it's obvious which half scores whom.
                        Rectangle().fill(Theme.teamColor(board.info(slot)?.color).opacity(0.85))
                            .frame(width: 5)
                            .frame(maxHeight: .infinity)
                            .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
                        Text("Tap this side for \(board.info(slot)?.shortName ?? "")")
                            .font(.footnote.weight(.medium)).foregroundStyle(Theme.text.opacity(0.85))
                            .shadow(color: .black.opacity(0.8), radius: 3)
                            .padding(.horizontal, 24).padding(.bottom, 74)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!board.canScore || board.flow.prompt != nil || board.flow.asksToSwap)
                .accessibilityLabel("Point to \(board.info(slot)?.name ?? "team")")
                .accessibilityIdentifier("live.tap.\(side.rawValue)")
            }
        }
    }

    // MARK: Status and controls

    private var overlayControls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                statusPills
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if session.kind == .filming, app.access(teamId: session.teamId) != nil {
                        Button { inviting = true } label: {
                            ViewThatFits {
                                Label("Invite scorer", systemImage: "person.badge.plus")
                                Image(systemName: "person.badge.plus")
                            }
                        }
                            .buttonStyle(OverlayButtonStyle())
                            .accessibilityLabel("Invite scorer")
                            .accessibilityIdentifier("live.invite")
                    }
                    Button("End") { confirmEnd = true }
                        .buttonStyle(OverlayButtonStyle())
                        .accessibilityIdentifier("live.end")
                }
            }
            .overlay(alignment: .top) { CompactScore(board: board) }
            if let message = live.banner ?? board.problem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(message).font(.footnote.weight(.medium)).lineLimit(2)
                    if live.canRetryStream {
                        Button("Retry stream") { live.retryStream() }.font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.scrim, in: Capsule())
                .accessibilityIdentifier("live.banner")
            }
            Spacer()
            HStack(alignment: .bottom) {
                Button { board.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(OverlayButtonStyle())
                    .disabled(!board.canUndo)
                    .accessibilityIdentifier("live.undo")
                Button { board.swapSides() } label: { Label("Swap sides", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(OverlayButtonStyle())
                    .accessibilityIdentifier("live.swap")
                if live.canStartRecording {
                    Button { Task { await live.startRecording() } } label: { Label("Record", systemImage: "record.circle") }
                        .buttonStyle(OverlayButtonStyle())
                        .accessibilityIdentifier("live.record")
                }
                Spacer()
                if board.scoringElsewhere {
                    Button { board.takeOver() } label: { Label("Scoring on another phone · Take over", systemImage: "hand.raised") }
                        .buttonStyle(OverlayButtonStyle())
                        .accessibilityIdentifier("live.takeOver")
                }
                if watch.isWatchConnected {
                    Image(systemName: "applewatch").foregroundStyle(Theme.muted).padding(10)
                        .background(Theme.scrim, in: Circle())
                        .accessibilityLabel("Apple Watch is following this match")
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .padding(.leading, 34) // clear the Dynamic Island / notch in landscape
        .padding(.trailing, 34)
    }

    private var statusPills: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            if live.isLive {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 7, height: 7)
                    Text("LIVE").font(.footnote.weight(.bold)).kerning(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.live, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("live.livePill")
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Duration.seconds(live.film.elapsedSeconds).formatted(.time(pattern: .minuteSecond)))
                    .font(.footnote.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 6))
        }
            Text([live.recordingLabel, live.streamLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote.weight(.medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.scrim, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("live.status")
        }
        .fixedSize()
    }

    @ViewBuilder private var modal: some View {
        if board.isEnded {
            Theme.ground.opacity(0.6).ignoresSafeArea()
            MatchOverCard(board: board, savingVideo: savingVideo || live.film.state == .stopping) {
                app.finish(lastSnapshot: board.snapshot)
            }
        } else if let prompt = board.flow.prompt {
            Theme.ground.opacity(0.6).ignoresSafeArea()
            SetPointCard(board: board, prompt: prompt)
        } else if board.flow.asksToSwap {
            Theme.ground.opacity(0.6).ignoresSafeArea()
            SwapSidesCard(board: board)
        }
    }

    private func end(endMatch: Bool) async {
        savingVideo = true
        await live.finish(endMatch: endMatch)
        savingVideo = false
        if !board.isEnded { app.finish(lastSnapshot: board.snapshot) }
    }
}

/// The camera picture, or a labeled stand-in on the Simulator.
private struct CameraLayer: View {
    @ObservedObject var film: FilmModel
    var body: some View {
        ZStack {
            Color(hex: "#262A30")
            #if DEBUG && targetEnvironment(simulator)
            SimulatedCourt()
            #else
            if let session = film.captureSession {
                CameraPreviewView(session: session)
            } else {
                ProgressView().tint(Theme.text)
            }
            #endif
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator stand-in for the camera: a court seen from the stands.
private struct SimulatedCourt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: "#2E3238"), Color(hex: "#1D2025")], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(hex: "#8A6A4A"))
                    .overlay(Rectangle().stroke(Color(hex: "#E9E2D6"), lineWidth: 4))
                    .frame(width: w * 0.8, height: h * 0.52).offset(x: w * 0.1, y: h * 0.42)
                Rectangle().fill(Color(hex: "#1B1D21")).frame(width: 8, height: h * 0.64).offset(x: w * 0.5 - 4, y: h * 0.3)
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: w * 0.7, height: 3).offset(x: w * 0.15, y: h * 0.34)
                Text("Simulator camera").font(.caption2).foregroundStyle(Theme.secondary)
                    .offset(x: w - 130, y: h - 26)
            }
        }
    }
}
#endif
