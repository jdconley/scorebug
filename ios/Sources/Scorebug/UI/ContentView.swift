import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var film: FilmModel
    @ObservedObject var streaming: CaptureStreamingModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        tabs
            .task(id: scenePhase) { await monitorRecording() }
            .task(id: scenePhase) { await monitorStreamingControl() }
            .task(id: scenePhase) { await monitorStreamingHealth() }
            .onChange(of: film.state) { _, state in updateIdleTimer(state) }
            .onChange(of: scenePhase) { _, phase in stopIfBackgrounded(phase) }
    }
    private var tabs: some View {
        TabView {
            FilmView(model: film, streaming: streaming).tabItem { Label("Film", systemImage: "video") }
            NativeScoringView().tabItem { Label("Score", systemImage: "sportscourt") }
            RecordingsView(model: film).tabItem { Label("Recordings", systemImage: "rectangle.stack") }
        }
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
        while !Task.isCancelled {
            await streaming.pollControl()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    @MainActor private func monitorStreamingHealth() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            streaming.pollLocalHealth()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
    @MainActor private func updateIdleTimer(_ state: FilmModel.State) {
        UIApplication.shared.isIdleTimerDisabled = state == .starting || state == .recording || state == .stopping
    }
    @MainActor private func stopIfBackgrounded(_ phase: ScenePhase) {
        if phase == .background, film.canStop { Task { await film.stop() } }
    }

}

private struct FilmView: View {
    @ObservedObject var model: FilmModel
    @ObservedObject var streaming: CaptureStreamingModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    preview
                    if model.isScanning { ProgressView("Checking saved recordings…") }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status).font(.headline).accessibilityIdentifier("film.status")
                            Text(Duration.seconds(model.elapsedSeconds).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit().font(.title)
                                .accessibilityIdentifier("film.duration")
                                .accessibilityValue(String(format: "%.2f", model.elapsedSeconds))
                        }
                        Spacer()
                        if model.canStop {
                            Button("Stop recording", role: .destructive) { Task { await model.stop() } }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("film.stop")
                        } else {
                            Button("Record video") { Task { await model.start() } }
                                .buttonStyle(.borderedProminent).disabled(!model.canStart)
                                .accessibilityIdentifier("film.start")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Saved on this device", systemImage: "internaldrive")
                        Text("1080p · 30 fps · Audio included").foregroundStyle(.secondary)
                        if let bytes = model.freeBytes {
                            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) available")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("You can switch to Score while recording. Keep the app open to continue filming.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    StreamingControlsView(model: streaming)
                    if let message = model.message {
                        Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("film.message")
                    }
                }.padding()
            }.navigationTitle("Film")
        }
    }
    private var status: String {
        switch model.state {
        case .idle: "Ready to record"
        case .starting: "Starting recording…"
        case .recording: "Recording"
        case .stopping: "Saving recording…"
        case .failed: "Recording stopped with an error"
        }
    }
    @ViewBuilder private var preview: some View {
        #if DEBUG && targetEnvironment(simulator)
        VStack(spacing: 12) {
            Image(systemName: "video.badge.waveform").font(.largeTitle)
            Text("Simulator video source").font(.headline)
            Text("Generated video and tone use the same recorder as the phone camera.")
                .font(.caption).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity).frame(height: 190)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        #else
        if let session = model.captureSession {
            CameraPreviewView(session: session).aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ContentUnavailableView("Ready to film", systemImage: "video", description: Text("The camera and microphone start when you record."))
                .frame(height: 190)
        }
        #endif
    }
}

private struct RecordingsView: View {
    @ObservedObject var model: FilmModel
    @State private var showPlayer = false
    var body: some View {
        NavigationStack {
            List {
                if model.isScanning { ProgressView("Checking saved recordings…") }
                if model.recordings.isEmpty {
                    ContentUnavailableView("No saved recordings", systemImage: "video", description: Text("Record a video in Film. Saved video stays on this device."))
                }
                ForEach(model.recordings) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.createdAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                        HStack {
                            Text(status(entry.status))
                            Spacer()
                            Text(Duration.seconds(entry.duration).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                        }.foregroundStyle(.secondary)
                        if let reason = entry.reason { Text(reason).font(.caption) }
                        Button(entry.status == .recoverable ? "Recover and export MP4" : "Export MP4") {
                            Task {
                                await model.export(id: entry.id)
                                if model.selectedExport != nil { showPlayer = true }
                            }
                        }
                        .disabled(!entry.canExport || !model.canStart || model.exportingID != nil)
                        .accessibilityIdentifier("recordings.\(entry.status == .recoverable ? "recover" : "export").\(entry.id)")
                        if model.exportingID == entry.id { ProgressView("Preparing and checking video…") }
                    }.padding(.vertical, 4)
                }
                if let message = model.message { Text(message).accessibilityIdentifier("recordings.message") }
            }
            .navigationTitle("Recordings")
            .task { await model.refreshRecordings() }
            .refreshable { await model.refreshRecordings() }
            .sheet(isPresented: $showPlayer) {
                if let url = model.selectedExport { RecordingPlayer(url: url) }
            }
        }
    }
    private func status(_ status: RecordingEntry.Status) -> String {
        switch status {
        case .completed: "Completed"
        case .recoverable: "Recoverable"
        case .unavailable: "Unavailable"
        }
    }
}

private struct RecordingPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var playbackError: String?
    @State private var playbackSeconds = 0.0
    @State private var timeObserver: Any?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit)
                Text("MP4 ready").font(.headline).accessibilityIdentifier("recordings.exportReady")
                Button("Play video") { player?.play() }
                    .disabled(player == nil).accessibilityIdentifier("recordings.play")
                Text(Duration.seconds(playbackSeconds).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().accessibilityIdentifier("recordings.playbackTime")
                    .accessibilityValue(String(format: "%.2f", playbackSeconds))
                Text("The original recording is kept on this device.").font(.callout).foregroundStyle(.secondary)
                if let playbackError { Text(playbackError).foregroundStyle(.red).font(.caption) }
                ShareLink(item: url) { Label("Share video", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }.padding()
                .navigationTitle("Recorded video")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("recordings.closePlayer")
                } }
        }
        .onAppear {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let prepared = AVPlayer(url: url)
                player = prepared
                timeObserver = prepared.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { time in
                    if time.seconds.isFinite { playbackSeconds = time.seconds }
                }
            } catch { playbackError = "Playback audio could not start: \(error.localizedDescription)" }
        }
        .onDisappear {
            player?.pause()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
