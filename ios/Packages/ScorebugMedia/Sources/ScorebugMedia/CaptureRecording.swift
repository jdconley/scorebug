import Foundation

/// Strongly owns one source and one existing bounded recording session. The
/// session is exclusively controlled by this owner; do not start/stop/offer to it
/// separately. No additional media buffer or archive worker is created here.
///
/// start/stop waiter cancellation does not abandon capture: call cancel() for
/// explicit failure. A stop during startup cancels that incomplete start. Stop
/// joins source quiescence before asking RecordingSession to drain/finalize.
/// Releasing this owner cancels and schedules source teardown.
public final class CaptureRecording: Sendable {
    private let core: CaptureRecordingCore
    public init(source: any CaptureSource, session: RecordingSession) {
        core = CaptureRecordingCore(source: source, session: session)
    }
    deinit { core.cancel() }
    public var snapshot: RecordingSessionSnapshot { core.session.snapshot }
    public func start() async throws { try await core.start() }
    public func stop() async throws -> RecoveredArchive { try await core.stop() }
    public func cancel() { core.cancel() }
}

/// Mutable lifecycle state is lock protected. Only the startup task invokes
/// prepare/start; the single stop task joins startup before invoking source.stop.
private final class CaptureRecordingCore: @unchecked Sendable {
    let session: RecordingSession
    private let source: any CaptureSource
    private let ingress: CaptureIngress
    private let lock = NSLock()
    private var startup: Task<Void, Error>?
    private var shutdown: Task<RecoveredArchive, Error>?
    private var starting = false
    private var stopRequested = false

    init(source: any CaptureSource, session: RecordingSession) {
        self.source = source; self.session = session
        ingress = CaptureIngress(session: session)
    }

    func start() async throws {
        let pending = try lock.withLock {
            guard startup == nil, !stopRequested else { throw RecordingSessionError.invalidState }
            starting = true
            let pending = Task.detached { try await self.runStart() }
            startup = pending
            return pending
        }
        do { try await pending.value }
        catch {
            // Cleanup joins startup outside the startup task itself.
            if let stopping = requestStop() { _ = await stopping.result }
            throw error
        }
    }

    private func runStart() async throws {
        do {
            let callbacks = CaptureSourceCallbacks(sample: { [ingress, weak self] sample in
                if ingress.offer(sample) { self?.requestStop() }
            }, event: { [ingress, weak self] event in
                if ingress.fail(event) { self?.requestStop() }
            })
            let origin = try await source.prepare(callbacks: callbacks)
            try checkActive()
            try await session.start(at: origin)
            try checkActive()
            ingress.open()
            try await source.start()
            try lock.withLock {
                if let failure = session.snapshot.failure { throw failure }
                guard !stopRequested else { throw RecordingSessionError.cancelled }
                starting = false
            }
        } catch {
            session.failCapture(reason: "Capture startup failed")
            throw session.snapshot.failure ?? .captureFailed("Capture startup failed")
        }
    }

    private func checkActive() throws {
        try lock.withLock {
            if let failure = session.snapshot.failure { throw failure }
            guard !stopRequested else { throw RecordingSessionError.cancelled }
        }
    }

    @discardableResult private func requestStop() -> Task<RecoveredArchive, Error>? {
        lock.withLock {
            if let shutdown { return shutdown }
            guard let startup else { return nil }
            stopRequested = true
            if starting { session.cancel() }
            let shutdown = Task.detached {
                _ = await startup.result
                await self.source.stop()
                self.ingress.close()
                return try await self.session.stop()
            }
            self.shutdown = shutdown
            return shutdown
        }
    }

    func stop() async throws -> RecoveredArchive {
        guard let pending = requestStop() else {
            throw session.snapshot.failure ?? RecordingSessionError.invalidState
        }
        return try await pending.value
    }

    func cancel() {
        session.cancel()
        lock.withLock { stopRequested = true }
        requestStop()
    }
}

/// Callbacks strongly retain the ingress/session, never the lifecycle owner. A
/// short ingress lock makes closing admission atomic with in-flight callbacks;
/// the source's stop contract also quiesces its own callback queues.
private final class CaptureIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let session: RecordingSession
    private var acceptsSamples = false
    private var closed = false
    init(session: RecordingSession) { self.session = session }
    func open() { lock.withLock { if !closed { acceptsSamples = true } } }
    func close() { lock.withLock { closed = true; acceptsSamples = false } }

    /// Returns true only when lifecycle teardown should be requested.
    func offer(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock {
            guard acceptsSamples, !closed else { return false }
            return !session.offer(sample) && session.snapshot.failure != nil
        }
    }
    func fail(_ event: CaptureSourceEvent) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            let reason: String
            switch event {
            case .droppedSample: reason = "Capture dropped a sample"
            case .interrupted: reason = "Capture interrupted"
            case .failed: reason = "Capture failed"
            }
            session.failCapture(reason: reason)
            return true
        }
    }
}
