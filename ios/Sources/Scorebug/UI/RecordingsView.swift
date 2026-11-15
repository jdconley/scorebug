import AVFoundation
import AVKit
import Photos
import ScorebugCore
import SwiftUI
import UIKit

struct RecordingsView: View {
    @ObservedObject var film: FilmModel
    let preferences: AppPreferences
    @State private var exported: [String: URL] = [:]
    @State private var playing: URL?
    @State private var sharing: URL?
    @State private var note: String?
    @State private var working: (id: String, action: Action)?
    @Environment(\.dismiss) private var dismiss

    enum Action { case play, save, share }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(freeSpace).font(.subheadline).foregroundStyle(Theme.secondary)
                if let note {
                    Text(note).font(.callout).foregroundStyle(Theme.text)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("recordings.note")
                }
                if film.isScanning && film.recordings.isEmpty { ProgressView("Checking saved recordings…").padding(.top, 40) }
                if !film.isScanning && film.recordings.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "video").font(.largeTitle).foregroundStyle(Theme.secondary)
                        Text("No recordings yet").font(.headline)
                        Text("Every match you film is saved here, on this phone.").foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(film.recordings) { entry in
                    RecordingCard(entry: entry, recap: preferences.recordingMatches[entry.id], film: film,
                                  working: working?.id == entry.id ? working?.action : nil,
                                  disabled: working != nil || !film.canStart) { action in
                        Task { await run(action, entry) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.ground, for: .navigationBar)
        .task { await film.refreshRecordings() }
        .refreshable { await film.refreshRecordings() }
        .fullScreenCover(item: Binding(get: { playing.map(IdentifiedURL.init) }, set: { playing = $0?.url })) { item in
            RecordingPlayer(url: item.url)
        }
        .sheet(item: Binding(get: { sharing.map(IdentifiedURL.init) }, set: { sharing = $0?.url })) { item in
            ActivitySheet(items: [item.url]).ignoresSafeArea()
        }
    }

    private var freeSpace: String {
        guard let bytes = film.freeBytes else { return "Saved on this iPhone" }
        return "Saved on this iPhone · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free"
    }

    /// Recordings are kept as fragments; Play, Save and Share make (and check) an MP4 first.
    private func run(_ action: Action, _ entry: RecordingEntry) async {
        note = nil
        working = (entry.id, action)
        defer { working = nil }
        var url = exported[entry.id]
        if url == nil {
            await film.export(id: entry.id)
            url = film.selectedExport
            exported[entry.id] = url
        }
        guard let url else { note = film.message ?? "Couldn't prepare that video."; return }
        switch action {
        case .play: playing = url
        case .share: sharing = url
        case .save: note = await PhotoSaver.save(url)
        }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct RecordingCard: View {
    let entry: RecordingEntry
    let recap: MatchRecap?
    @ObservedObject var film: FilmModel
    let working: RecordingsView.Action?
    let disabled: Bool
    let perform: (RecordingsView.Action) -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.line)
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: "video").foregroundStyle(Theme.secondary) }
                }
                .frame(width: 88, height: 50).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recap?.title ?? "Recording").font(Theme.score(20)).lineLimit(1)
                    Text(meta).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(2)
                    if let reason = entry.reason, entry.status != .completed {
                        Text(entry.status == .recoverable ? "Interrupted · the video saved so far can be recovered" : reason)
                            .font(.caption).foregroundStyle(Theme.warn).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                action("Play", .play, icon: "play.fill")
                action("Save to Photos", .save, icon: "square.and.arrow.down")
                action("Share", .share, icon: "square.and.arrow.up", iconOnly: true)
            }
            .disabled(!entry.canExport || disabled)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: entry.id) {
            if let url = await film.thumbnail(id: entry.id), let image = UIImage(contentsOfFile: url.path) { thumbnail = image }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.\(entry.id)")
    }

    private var meta: String {
        var parts = [entry.createdAt.formatted(.relative(presentation: .named)),
                     Duration.seconds(entry.duration).formatted(entry.duration >= 3600 ? .time(pattern: .hourMinuteSecond) : .time(pattern: .minuteSecond))]
        if let resolution = entry.resolutionLabel { parts.append(resolution) }
        parts.append(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
        if let recap, !recap.setScores.isEmpty { parts.append(recap.setScores) }
        return parts.joined(separator: " · ")
    }

    private func action(_ title: String, _ kind: RecordingsView.Action, icon: String, iconOnly: Bool = false) -> some View {
        Button { perform(kind) } label: {
            Group {
                if working == kind { ProgressView().tint(Theme.text) }
                else if iconOnly { Image(systemName: icon) }
                else { Label(title, systemImage: icon) }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: iconOnly ? 52 : .infinity, minHeight: 44)
            .background(Theme.line, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

enum PhotoSaver {
    static func save(_ url: URL) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Scorebug can't add to Photos. Allow it in Settings › Privacy › Photos."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return "Saved to Photos."
        } catch {
            return "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct RecordingPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(Theme.scrim, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("recordings.closePlayer")
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayer(url: url)
            player = item
            item.play()
        }
        .onDisappear {
            player?.pause(); player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
