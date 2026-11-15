import Combine
import Foundation
import ScorebugCore

/// The filming phone's live screen: recording and the stream start together,
/// and the stream can fail, reconnect or be skipped without touching the recording.
@MainActor final class LiveModel: ObservableObject {
    let scoreboard: ScoreboardModel
    let film: FilmModel
    let streaming: CaptureStreamingModel
    let session: MatchSession

    @Published private(set) var began = false
    @Published private(set) var finishing = false

    private let config: ServerConfig
    private let preferences: AppPreferences
    private let recordIn4K: Bool
    private var bag: Set<AnyCancellable> = []

    init(session: MatchSession, config: ServerConfig, scoreboard: ScoreboardModel, film: FilmModel,
         streaming: CaptureStreamingModel, preferences: AppPreferences, recordIn4K: Bool) {
        self.session = session
        self.config = config
        self.scoreboard = scoreboard
        self.film = film
        self.streaming = streaming
        self.preferences = preferences
        self.recordIn4K = recordIn4K
        // Re-publish engine changes so one observed object drives the screen.
        film.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        streaming.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        scoreboard.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// Go live: start recording, then (unless record only) the stream.
    func begin() async {
        guard !began else { return }
        began = true
        await startRecording()
    }

    /// Starts (or restarts) the recording. Waits out the launch-time scan of saved
    /// recordings, which briefly blocks a new recording after a relaunch mid-match.
    func startRecording() async {
        guard !film.canStop else { return }
        for _ in 0..<300 where !film.canStart && film.state != .stopping { try? await Task.sleep(for: .milliseconds(100)) }
        film.selectQuality(recordIn4K ? .uhd2160 : .hd1080)
        await film.start()
        noteRecording()
        // The stream rides on the recording, never the other way round.
        guard film.state == .recording, !session.recordOnly, let token = config.ownerToken else { return }
        streaming.endpoint = config.endpoint
        streaming.installationToken = token
        await streaming.connect()
        streaming.requestStartStreaming()
    }

    /// Shown when the camera isn't recording (start failed, or it stopped with an error).
    var canStartRecording: Bool { began && !finishing && !film.canStop && film.state != .stopping }

    var isRecording: Bool { film.state == .recording || film.state == .starting }
    var isLive: Bool { streaming.status == .live || streaming.status == .reconnecting }

    /// "REC 1080p"
    var recordingLabel: String {
        switch film.state {
        case .starting: "Starting camera…"
        case .recording: "REC \(film.recordingQuality.label)"
        case .stopping: "Saving…"
        case .idle, .failed: "Not recording"
        }
    }

    /// "720p out · good", or nil when record only.
    var streamLabel: String? {
        guard !session.recordOnly else { return "Record only" }
        switch streaming.status {
        case .live:
            guard let rung = streaming.streamQuality else { return "Live" }
            return "\(rung.label) out · \(rung >= .p720 ? "good" : "weak")"
        case .reconnecting: return "Reconnecting stream…"
        case .starting: return "Going live…"
        case .recordingOnly, .off: return began && film.state == .recording ? "Stream off" : nil
        }
    }

    /// A non-blocking stream problem. Recording keeps going regardless.
    var banner: String? {
        if film.state == .failed { return film.message }
        guard !session.recordOnly, streaming.status != .live else { return nil }
        return streaming.message
    }

    var canRetryStream: Bool {
        !session.recordOnly && film.state == .recording && streaming.status == .recordingOnly && streaming.canStart
    }

    func retryStream() {
        guard canRetryStream else { return }
        Task { await streaming.pollControl(); streaming.requestStartStreaming() }
    }

    /// Tie the recording to this match for the Recordings list.
    func noteRecording() {
        guard let id = film.currentCapture?.id, let snapshot = scoreboard.snapshot else { return }
        var map = preferences.recordingMatches
        map[id] = MatchRecap(snapshot: snapshot, date: session.startedAt)
        preferences.recordingMatches = map
    }

    /// End: closes the match (when still open), stops the stream, then the recording.
    func finish(endMatch: Bool) async {
        guard !finishing else { return }
        finishing = true
        if endMatch { await scoreboard.endMatch() }
        noteRecording()
        scoreboard.isLiveForWatch = false
        await streaming.stopStreaming()
        await film.stop()
    }
}
