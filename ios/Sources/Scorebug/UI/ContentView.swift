import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var camera: CameraSession
    @State private var showSettings = false
    @State private var setup = GameSetupModel()
    @State private var activeGameId: String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: cameraSessionForPreview())
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    panel
                }
                .padding()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task {
            await camera.prepare()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            if activeGameId == nil {
                gameSetupPanel
            } else {
                publishingPanel
            }
            if let err = errorText {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var gameSetupPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scorebug").font(.headline)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gear") }
            }
            HStack {
                TextField("Home", text: $setup.home).textFieldStyle(.roundedBorder)
                TextField("HOME", text: $setup.homeShort).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            HStack {
                TextField("Away", text: $setup.away).textFieldStyle(.roundedBorder)
                TextField("AWAY", text: $setup.awayShort).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            SecureField("YouTube stream key", text: $setup.streamKey).textFieldStyle(.roundedBorder)
            Button(action: start) {
                Text(busy ? "Starting…" : "Start Game")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !setup.isValid || !settings.isConfigured)
        }
    }

    private var publishingPanel: some View {
        VStack(spacing: 8) {
            Text("LIVE").font(.headline).foregroundStyle(.red)
            Text("game \(activeGameId?.prefix(8) ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button("End Game", role: .destructive, action: end)
                .buttonStyle(.bordered)
        }
    }

    private func cameraSessionForPreview() -> AVCaptureSession {
        // CameraSession exposes its internal AVCaptureSession lazily through a
        // computed property to keep the API surface small.
        Mirror(reflecting: camera).children
            .first { $0.label == "session" }?.value as? AVCaptureSession ?? AVCaptureSession()
    }

    private func start() {
        guard let client = ControlPlaneClient(baseURL: settings.controlPlaneURL, token: settings.phoneToken) else {
            errorText = "Bad control-plane URL."
            return
        }
        busy = true
        errorText = nil
        Task {
            do {
                let req = StartGameRequest(
                    homeTeam: TeamSpec(name: setup.home, shortName: setup.homeShort, color: "#1e3a8a"),
                    awayTeam: TeamSpec(name: setup.away, shortName: setup.awayShort, color: "#b91c1c"),
                    youtubeStreamKey: setup.streamKey
                )
                let res = try await client.startGame(req)
                await camera.startPublishing(credentials: res.publish)
                activeGameId = res.id
            } catch {
                errorText = "Start failed: \(error)"
            }
            busy = false
        }
    }

    private func end() {
        guard let id = activeGameId else { return }
        guard let client = ControlPlaneClient(baseURL: settings.controlPlaneURL, token: settings.phoneToken) else { return }
        Task {
            await camera.stopPublishing()
            try? await client.endGame(id: id)
            activeGameId = nil
        }
    }
}

struct GameSetupModel {
    var home: String = ""
    var homeShort: String = ""
    var away: String = ""
    var awayShort: String = ""
    var streamKey: String = ""
    var isValid: Bool {
        !home.isEmpty && !homeShort.isEmpty && !away.isEmpty && !awayShort.isEmpty && streamKey.count >= 8
    }
}
