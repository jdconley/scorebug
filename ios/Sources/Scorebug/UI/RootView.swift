import ScorebugCore
import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var film: FilmModel
    @ObservedObject var streaming: CaptureStreamingModel
    @ObservedObject var watch: PhoneWatchLink

    var body: some View {
        withLinks.modifier(EngineMonitors(film: film, streaming: streaming))
    }

    private var withLinks: some View {
        content
            .screenBackground()
            .onOpenURL { url in app.open(url.absoluteString) }
            .sheet(item: $app.pendingLink) { link in
                LinkConfirmSheet(link: link, app: app).presentationDetents([.medium])
            }
    }

    @ViewBuilder private var content: some View {
        switch app.route {
        case .connect:
            ConnectView(app: app)
        case .home:
            HomeView(app: app, film: film)
        case .filming(let session):
            LiveScreen(app: app, session: session, film: film, streaming: streaming, watch: watch)
                .id(session.credential.gameId)
        case .scoring(let session):
            ScorerScreen(app: app, session: session, watch: watch)
                .id(session.credential.gameId)
        }
    }

/// Recording health, stream control and stream health polling while the app is active.
private struct EngineMonitors: ViewModifier {
    @ObservedObject var film: FilmModel
    @ObservedObject var streaming: CaptureStreamingModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) { await monitorRecording() }
            .task(id: scenePhase) { await monitorStreamingControl() }
            .task(id: scenePhase) { await monitorStreamingHealth() }
            .onChange(of: film.state) { _, state in updateIdleTimer(state) }
            .onChange(of: scenePhase) { _, phase in stopIfBackgrounded(phase) }
    }

    @MainActor private func updateIdleTimer(_ state: FilmModel.State) {
        UIApplication.shared.isIdleTimerDisabled = state == .starting || state == .recording || state == .stopping
    }

    /// Recording needs the app open; leaving it saves what was filmed.
    @MainActor private func stopIfBackgrounded(_ phase: ScenePhase) {
        if phase == .background, film.canStop { Task { await film.stop() } }
    }

    @MainActor private func monitorRecording() async {
        guard scenePhase == .active else { return }
        await film.refreshRecordings()
        while !Task.isCancelled {
            await film.pollHealth()
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    @MainActor private func monitorStreamingControl() async {
        guard scenePhase == .active else { return }
        await streaming.restore()
        await ControlPollSchedule.run(interval: { streaming.controlPollInterval },
                                      poll: { await streaming.pollBackgroundControl() })
    }

    @MainActor private func monitorStreamingHealth() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            streaming.pollLocalHealth()
            do { try await Task.sleep(for: CaptureStreamingModel.publishingHealthInterval) } catch { return }
        }
    }
}
}

/// A link never changes servers or joins a match without a tap.
private struct LinkConfirmSheet: View {
    let link: AppModel.PendingLink
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Theme.line).frame(width: 40, height: 5).padding(.top, 10)
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.text)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button(confirm) { Task { await app.confirmPendingLink() } }
                .buttonStyle(BigButtonStyle())
                .disabled(app.busy)
                .accessibilityIdentifier("link.confirm")
            Button("Not now") { app.pendingLink = nil }
                .foregroundStyle(Theme.muted).frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#111418").ignoresSafeArea())
    }

    private var host: String {
        switch link {
        case .connect(let server, _): server.url.host ?? server.url.absoluteString
        case .join(.link(let server, _)): server.url.host ?? server.url.absoluteString
        case .join(.code): app.config?.host ?? "your server"
        }
    }
    private var icon: String { if case .connect = link { "server.rack" } else { "person.2.fill" } }
    private var title: String { if case .connect = link { "Connect to \(host)?" } else { "Help score a match?" } }
    private var detail: String {
        switch link {
        case .connect:
            if let current = app.config, current.isOwner, current.host != host {
                return "This phone uses \(current.host) now. Connecting switches it to \(host)."
            }
            return "This phone will create matches, film and stream through this server."
        case .join:
            return "You'll score the match on \(host) from this phone. No camera needed."
        }
    }
    private var confirm: String { if case .connect = link { "Connect" } else { "Join and score" } }
}

enum OrientationLock {
    @MainActor static func set(_ mask: UIInterfaceOrientationMask, rotateTo target: UIInterfaceOrientationMask) {
        AppDelegate.orientations = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
    }
}

enum Haptics {
    @MainActor static func play(_ feedback: ScoreboardModel.Feedback) {
        switch feedback {
        case .point: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .undo: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .setEnded: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .problem: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
