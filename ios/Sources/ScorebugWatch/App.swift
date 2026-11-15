import ScorebugCore
import SwiftUI
import WatchKit

@main
struct ScorebugWatchApp: App {
    @StateObject private var link = WatchLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRootView(link: link)
                .onAppear { link.activate() }
                .onChange(of: phase) { _, phase in if phase == .active { link.refresh() } }
        }
    }
}

struct WatchRootView: View {
    @ObservedObject var link: WatchLink

    var body: some View {
        if let state = link.state, !state.ended {
            if let prompt = state.prompt {
                WatchSetPointView(link: link, prompt: prompt)
            } else if state.asksToSwap {
                WatchSwapView(link: link, state: state)
            } else {
                WatchScoreView(link: link, state: state)
            }
        } else {
            WatchIdleView(link: link, ended: link.state?.ended == true)
        }
    }
}

/// Two big team-colored halves ordered by court side; tap to score, long-press to undo.
struct WatchScoreView: View {
    @ObservedObject var link: WatchLink
    let state: WatchRemote.State

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(state.header).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "#C9CED6"))
                Spacer()
                if state.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: "#FF6B60")).frame(width: 6, height: 6)
                        Text("LIVE").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: "#FF6B60"))
                    .accessibilityLabel("Live")
                }
            }
            .padding(.horizontal, 8)
            half(state.left)
            half(state.right)
            HStack(spacing: 6) {
                Button { link.send(.undo, haptic: .directionDown) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!state.canUndo)
                    .accessibilityLabel("Undo")
                Button { link.send(.swapSides) } label: { Image(systemName: "arrow.left.arrow.right") }
                    .accessibilityLabel("Swap sides")
            }
            .font(.system(size: 15, weight: .semibold))
            .buttonStyle(.bordered)
            .frame(height: 34)
            if let note = state.note ?? (link.connection == .phoneAway ? "iPhone out of reach" : nil) {
                Text(note).font(.system(size: 11)).foregroundStyle(Color(hex: "#9AA3AE")).lineLimit(1)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .opacity(link.sending ? 0.85 : 1)
    }

    private func half(_ team: WatchRemote.Team) -> some View {
        let fill = Color(hex: team.color)
        let ink: Color = TeamPalette.prefersDarkText(on: team.color) ? Color(hex: "#0B0D10") : .white
        return Button { link.send(.point(team.slot)) } label: {
            HStack {
                Text(team.shortName).font(.custom("BarlowCondensed-Bold", size: 20)).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text("\(team.points)").font(.custom("BarlowCondensed-Bold", size: 44)).monospacedDigit()
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!state.canScore)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            if state.canUndo { link.send(.undo, haptic: .directionDown) }
        })
        .accessibilityLabel("Point to \(team.shortName)")
        .accessibilityValue("\(team.points)")
        .accessibilityHint("Long-press to undo the last point")
    }
}

struct WatchSetPointView: View {
    @ObservedObject var link: WatchLink
    let prompt: WatchRemote.Prompt
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("SET POINT").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: "#9AA3AE"))
                Text(prompt.title).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                Text(prompt.scoreLine).font(.custom("BarlowCondensed-Bold", size: 34))
                Button(prompt.confirmLabel) { link.send(.confirmSetEnd, haptic: .success) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                Button("Undo point") { link.send(.undo, haptic: .directionDown) }
                Button("Keep playing") { link.send(.declineSetEnd) }.font(.footnote)
            }
        }
    }
}

struct WatchSwapView: View {
    @ObservedObject var link: WatchLink
    let state: WatchRemote.State
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Switching sides?").font(.system(size: 17, weight: .bold))
                Text("\(state.right.shortName) ⇄ \(state.left.shortName)").font(.custom("BarlowCondensed-Bold", size: 22))
                Button("Yes, switch") { link.send(.answerSwap(true)) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                Button("Keep sides") { link.send(.answerSwap(false)) }
            }
        }
    }
}

struct WatchIdleView: View {
    @ObservedObject var link: WatchLink
    let ended: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: ended ? "flag.checkered" : "iphone")
                .font(.system(size: 30)).foregroundStyle(Color(hex: "#9AA3AE"))
            Text(ended ? "Match over" : "No match yet").font(.headline)
            Text(link.connection == .phoneAway
                 ? "Keep your iPhone nearby with Scorebug open."
                 : "Start or join a match in Scorebug on your iPhone. It shows up here.")
                .font(.footnote).foregroundStyle(Color(hex: "#9AA3AE")).multilineTextAlignment(.center)
        }
        .padding()
        .onTapGesture { link.refresh() }
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = TeamPalette.components(hex) ?? (0.6, 0.64, 0.68)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
