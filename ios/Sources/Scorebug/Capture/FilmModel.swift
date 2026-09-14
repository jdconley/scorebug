import AVFoundation
import Combine
import Foundation
import ScorebugMedia

/// Offline recording has no dependency on match setup, credentials or a server.
@MainActor final class FilmModel: ObservableObject {
    enum State: String { case idle, starting, recording, stopping, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var message: String?
    @Published private(set) var recordings: [RecordingEntry] = []
    @Published var selectedExport: URL?
    @Published private(set) var exportingID: String?
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var queueItems = 0
    @Published private(set) var queueBytes = 0
    @Published private(set) var writtenSamples = 0
    @Published private(set) var isScanning = false
    #if os(iOS)
    @Published private(set) var captureSession: AVCaptureSession?
    #endif

    var canStart: Bool { (state == .idle || state == .failed) && exportingID == nil && !isScanning }
    var canStop: Bool { state == .starting || state == .recording }
    private let library: RecordingLibrary
    private let profile: ArchiveProfile
    private let sourceFactory: () -> any CaptureSource
    private let sinkFactory: RecordingLibrary.SinkFactory
    private let durationReader: @Sendable (any RecordingArchiveSink) -> Double?
    private var draft: RecordingDraft?
    private var recorder: CaptureRecording?
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    private var readingDuration = false

    init(library: RecordingLibrary = RecordingLibrary(), profile: ArchiveProfile = ArchiveProfile(),
         sourceFactory: @escaping () -> any CaptureSource,
         sinkFactory: @escaping RecordingLibrary.SinkFactory = RecordingLibrary.defaultSinkFactory,
         durationReader: @escaping @Sendable (any RecordingArchiveSink) -> Double? = {
             ($0 as? SegmentedArchiveSink)?.writer.snapshot.acceptedDuration
         }) {
        self.library = library
        self.profile = profile
        self.sourceFactory = sourceFactory
        self.sinkFactory = sinkFactory
        self.durationReader = durationReader
    }

    func start() async {
        guard canStart else { return }
        state = .starting
        message = nil
        selectedExport = nil
        elapsedSeconds = 0
        queueItems = 0
        queueBytes = 0
        writtenSamples = 0
        shutdown = nil
        let pending = Task {
            let created = try await library.begin(profile: profile, sinkFactory: sinkFactory)
            draft = created
            guard state == .starting else { throw RecordingSessionError.cancelled }
            let source = sourceFactory()
            #if os(iOS)
            captureSession = (source as? IOSCameraCaptureSource)?.previewSession
            #endif
            let capture = CaptureRecording(source: source, session: try RecordingSession(sink: created.sink))
            recorder = capture
            try await capture.start()
        }
        startup = pending
        let result = await pending.result
        guard state == .starting else { return }
        switch result {
        case .success:
            state = .recording
            await pollHealth()
        case .failure:
            await stop()
        }
    }

    /// One shutdown joins startup, source quiescence, draining and durable status.
    /// A stop while permission/capture preparation is pending cancels that start.
    func stop() async {
        if let shutdown { await shutdown.value; return }
        guard canStop else { return }
        let wasStarting = state == .starting
        state = .stopping
        if wasStarting { recorder?.cancel() }
        let pending = Task {
            let setup = await startup?.result
            var failure: String?
            if case .failure(let error) = setup { failure = describe(error) }
            if wasStarting, failure == nil { failure = "Recording stopped before capture was ready." }
            if let recorder {
                do { _ = try await recorder.stop() }
                catch { failure = describe(error) }
                await updateCounters(recorder)
            }
            if let draft {
                do { try await library.finish(id: draft.id, failure: failure) }
                catch { failure = error.localizedDescription }
            }
            self.recorder = nil
            draft = nil
            startup = nil
            #if os(iOS)
            captureSession = nil
            #endif
            state = failure == nil ? .idle : .failed
            message = failure ?? "Recording saved on this device."
            await refreshRecordings()
        }
        shutdown = pending
        await pending.value
    }

    func refreshRecordings() async {
        // Historical recovery hashes every committed fragment. Keep those reads
        // out of the live capture/export workload, and serve cached rows instead.
        guard (state == .idle || state == .failed), exportingID == nil, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do { recordings = try await library.list(excludingID: draft?.id) }
        catch { message = "Recordings could not be read: \(error.localizedDescription)" }
        freeBytes = await library.availableBytes()
    }

    func export(id: String) async {
        guard canStart, exportingID == nil else { return }
        exportingID = id
        selectedExport = nil
        defer { exportingID = nil }
        do {
            selectedExport = try await library.export(id: id)
            message = "MP4 exported. The original recording is still on this device."
        } catch { message = "Export failed: \(error.localizedDescription). The original recording was kept." }
        freeBytes = await library.availableBytes()
    }

    /// Called at a modest UI cadence; no per-sample MainActor tasks are created.
    func pollHealth() async {
        if let recorder {
            await updateCounters(recorder)
            if self.recorder === recorder, recorder.snapshot.failure != nil, state == .recording { await stop() }
        }
        freeBytes = await library.availableBytes()
    }

    private func updateCounters(_ recording: CaptureRecording) async {
        guard recorder === recording else { return }
        // Session/mailbox counters use only short locks; they do not access disk.
        let snapshot = recording.snapshot
        queueItems = snapshot.queue.currentItems
        queueBytes = snapshot.queue.currentBytes
        writtenSamples = snapshot.writtenSamples
        guard !readingDuration, let draft else { return }
        readingDuration = true
        let recordingID = draft.id
        let sink = draft.sink
        let readDuration = durationReader
        // Writer snapshots may wait behind segment hashing/fsync. Keep that wait
        // off MainActor, with at most one read outstanding across all recordings.
        let duration = await Task.detached(priority: .utility) { readDuration(sink) }.value
        readingDuration = false
        guard recorder === recording, self.draft?.id == recordingID else { return }
        if let duration, duration.isFinite, duration >= 0 { elapsedSeconds = duration }
    }

    private func describe(_ error: Error) -> String {
        guard let error = error as? RecordingSessionError else { return error.localizedDescription }
        switch error {
        case .captureFailed(let reason): return "\(reason). Any video already saved was kept. Check Recordings for recovery options."
        case .overflow: return "The recording queue filled. Any video already saved was kept. Check Recordings for recovery options."
        case .backpressureTimedOut: return "Storage could not keep up with capture. Any video already saved was kept. Check Recordings for recovery options."
        case .cancelled: return "Recording was interrupted before completion. Any video already saved was kept. Check Recordings for recovery options."
        default: return "Recording failed (\(error)). Any video already saved was kept. Check Recordings for recovery options."
        }
    }
}
