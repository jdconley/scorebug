import AVFoundation
import Combine
import Foundation
import ScorebugMedia

/// Local recording resolution. 1080p30 by default; 4K is an opt-in that runs
/// hotter. The live stream ladder is independent and never exceeds 1080p.
enum RecordingQuality: String, CaseIterable, Identifiable {
    case hd1080, uhd2160
    static let recordIn4KKey = "scorebug.recording.recordIn4K"
    var id: String { rawValue }
    var label: String { self == .hd1080 ? "1080p" : "4K" }
    var profile: ArchiveProfile {
        self == .hd1080 ? ArchiveProfile() : ArchiveProfile(width: 3840, height: 2160, videoBitRate: 30_000_000)
    }
    static func saved(in defaults: UserDefaults) -> RecordingQuality {
        defaults.bool(forKey: recordIn4KKey) ? .uhd2160 : .hd1080
    }
}

extension ArchiveProfile {
    var isUHDRecording: Bool { width == 3840 && height == 2160 }
    // Preserve the same bounded number of NV12 frames at either offered quality.
    var captureQueueScale: Int { isUHDRecording ? 4 : 1 }
}

struct CurrentCapture: Sendable {
    let id: String
    let startedAt: String
    let tap: PublishingTap
    let profile: ArchiveProfile
    init(id: String, startedAt: String, tap: PublishingTap, profile: ArchiveProfile = .init()) {
        self.id = id; self.startedAt = startedAt; self.tap = tap; self.profile = profile
    }
}

/// Offline recording has no dependency on match setup, credentials or a server.
@MainActor final class FilmModel: ObservableObject {
    enum State: String { case idle, starting, recording, stopping, failed }
    @Published private(set) var currentCapture: CurrentCapture?
    var onCaptureChanged: ((CurrentCapture?) -> Void)?
    var onCaptureFinished: ((CurrentCapture, Bool) -> Void)?
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
    @Published private(set) var profile: ArchiveProfile
    var recordingQuality: RecordingQuality { profile.width == 3840 && profile.height == 2160 ? .uhd2160 : .hd1080 }
    @discardableResult func selectQuality(_ quality: RecordingQuality) -> Bool {
        guard canStart else { return false }
        profile = quality.profile
        preferences?.set(quality == .uhd2160, forKey: RecordingQuality.recordIn4KKey)
        return true
    }
    /// Persisted "Record in 4K" setting; off records 1080p30.
    var recordsIn4K: Bool { recordingQuality == .uhd2160 }
    private let preferences: UserDefaults?
    private let sourceFactory: (ArchiveProfile) throws -> any CaptureSource
    private let sinkFactory: RecordingLibrary.SinkFactory
    private let durationReader: @Sendable (any RecordingArchiveSink) -> Double?
    private var draft: RecordingDraft?
    private var recorder: CaptureRecording?
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    private var readingDuration = false
    #if DEBUG
    // Automatic diagnostics are restricted to the explicitly flagged simulator
    // fixture. Mac tests inject both dependencies without changing public factories.
    var archivePressureFactory: ((String) -> ArchivePressureDiagnostics)? = {
        #if targetEnvironment(simulator)
        guard ArchivePressureFixture.requested(environment: ProcessInfo.processInfo.environment) else { return nil }
        return { ArchivePressureDiagnostics(recordingID: $0) }
        #else
        return nil
        #endif
    }()
    var archivePressureWriter: ((ArchivePressureDiagnostics.Snapshot) async throws -> Void)? = {
        #if targetEnvironment(simulator)
        return { try await ArchivePressureFixture.writeClosed($0) }
        #else
        return nil
        #endif
    }()
    private var archivePressureDiagnostics: ArchivePressureDiagnostics?
    var fileFixtureStatisticsWriter: ((String, FileFixtureStatistics) async throws -> Void)? = {
        #if targetEnvironment(simulator)
        return { try await FileFixtureDiagnostics.writeClosed(recordingID: $0, statistics: $1) }
        #else
        return nil
        #endif
    }()
    private var fileFixtureSource: FileFixtureCameraSource?
    #endif

    convenience init(library: RecordingLibrary = RecordingLibrary(), profile: ArchiveProfile = ArchiveProfile(),
         sourceFactory: @escaping () throws -> any CaptureSource,
         sinkFactory: @escaping RecordingLibrary.SinkFactory = RecordingLibrary.defaultSinkFactory,
         durationReader: @escaping @Sendable (any RecordingArchiveSink) -> Double? = {
             ($0 as? SegmentedArchiveSink)?.writer.acceptedDuration
         }) {
        self.init(library: library, profile: profile, configuredSourceFactory: { _ in try sourceFactory() },
                  sinkFactory: sinkFactory, durationReader: durationReader)
    }

    init(library: RecordingLibrary = RecordingLibrary(), profile: ArchiveProfile? = nil,
         preferences: UserDefaults? = nil,
         configuredSourceFactory: @escaping (ArchiveProfile) throws -> any CaptureSource,
         sinkFactory: @escaping RecordingLibrary.SinkFactory = RecordingLibrary.defaultSinkFactory,
         durationReader: @escaping @Sendable (any RecordingArchiveSink) -> Double? = {
             ($0 as? SegmentedArchiveSink)?.writer.acceptedDuration
         }) {
        self.library = library
        self.preferences = preferences
        self.profile = profile ?? preferences.map { RecordingQuality.saved(in: $0).profile } ?? ArchiveProfile()
        self.sourceFactory = configuredSourceFactory
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
            let source: any CaptureSource
            do {
                // Do not construct a source after cancellation during archive setup.
                guard state == .starting else { throw RecordingSessionError.cancelled }
                source = try sourceFactory(profile)
            } catch {
                // No RecordingSession has taken ownership of this sink yet.
                created.sink.cancel()
                throw error
            }
            #if os(iOS)
            captureSession = (source as? IOSCameraCaptureSource)?.previewSession
            #endif
            let tap = PublishingTap()
            let session = try RecordingSession(sink: created.sink, maxBytes: 24 * 1024 * 1024 * profile.captureQueueScale)
            #if DEBUG
            fileFixtureSource = source as? FileFixtureCameraSource
            if let owner = archivePressureFactory?(created.id), owner.snapshot.recordingID == created.id {
                archivePressureDiagnostics = owner
                session.attachArchivePressureDiagnostics(owner)
                (source as? FixtureCameraSource)?.attachArchivePressureDiagnostics(owner)
                fileFixtureSource?.attachArchivePressureDiagnostics(owner)
                (created.sink as? SegmentedArchiveSink)?.writer.attachArchivePressureDiagnostics(owner)
            }
            #endif
            let capture = CaptureRecording(source: source, session: session, publishingTap: tap)
            recorder = capture
            try await capture.start()
            guard state == .starting else { throw RecordingSessionError.cancelled }
            let context = CurrentCapture(id: created.id, startedAt: ISO8601DateFormatter().string(from: Date()), tap: tap, profile: profile)
            currentCapture = context
            onCaptureChanged?(context)
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
        let endedCapture = currentCapture
        currentCapture = nil
        onCaptureChanged?(nil)
        if wasStarting { recorder?.cancel() }
        let pending = Task {
            let setup = await startup?.result
            var failure: String?
            if case .failure(let error) = setup { failure = describe(error) }
            if wasStarting, failure == nil { failure = "Recording stopped before capture was ready." }
            #if DEBUG
            var closedDiagnostics: ArchivePressureDiagnostics.Snapshot?
            var closedFileStatistics: FileFixtureStatistics?
            #endif
            if let recorder {
                do { _ = try await recorder.stop() }
                catch { failure = describe(error) }
                #if DEBUG
                // Freeze before metrics/storage reads can wait on unrelated I/O.
                closedDiagnostics = archivePressureDiagnostics?.close(snapshot: recorder.snapshot)
                closedFileStatistics = fileFixtureSource?.statistics
                #endif
                await updateCounters(recorder)
            }
            if let draft {
                do { try await library.finish(id: draft.id, failure: failure) }
                catch { failure = error.localizedDescription }
            }
            #if DEBUG
            if let closedDiagnostics, closedDiagnostics.recordingID == draft?.id,
               let writer = archivePressureWriter {
                // Export remains part of this joined stop. A diagnostic I/O error
                // must never replace the recording outcome or permit early restart.
                try? await writer(closedDiagnostics)
            }
            if let closedFileStatistics, closedFileStatistics.closed, let id = draft?.id,
               let writer = fileFixtureStatisticsWriter {
                try? await writer(id, closedFileStatistics)
            }
            fileFixtureSource = nil
            archivePressureDiagnostics = nil
            #endif
            self.recorder = nil
            draft = nil
            startup = nil
            #if os(iOS)
            captureSession = nil
            #endif
            if let endedCapture { onCaptureFinished?(endedCapture, failure != nil) }
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
        // Scalar duration reads avoid segment storage but still share the writer's
        // lifecycle lock. Keep native writer waits off MainActor, with at most one
        // read outstanding across all recordings.
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
