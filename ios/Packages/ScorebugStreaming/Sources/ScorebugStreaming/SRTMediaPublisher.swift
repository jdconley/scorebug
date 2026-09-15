import Foundation
import ScorebugMedia

/// One terminal SRT attempt for PublishingSession. Configuration, connection and
/// shutdown may overlap: stopping prevents late readiness and joins one shielded
/// close task. Construct a fresh instance for a later attempt. Capture callbacks
/// feed PublishingSession's bounded mailbox, never this actor directly.
public actor SRTMediaPublisher: MediaPublisher {
    public enum PublisherError: Error, Equatable, Sendable {
        case invalidState, cancelled, startFailed, appendFailed, invalidSample, notPublishing, bitRateUpdateFailed
    }
    public typealias TransportMetrics = (rttMilliseconds: Double, droppedPackets: Int32, sentBytes: UInt64)
    private enum State { case prepared, starting, publishing, stopped }
    private let operations: Operations
    private var state = State.prepared
    private var startup: Task<Void, Error>?
    private var shutdown: Task<Void, Never>?
    private var bitRateUpdating = false

    /// The destination is captured in an opaque operation, never in error text or
    /// a persistent/public diagnostic state. The control-plane client validates it.
    public init(url: URL, stopPolicy: SRTStopPolicy = .init(), observations: VideoFrameObservationOwner? = nil) {
        let adapter = SRTPublisher(stopPolicy: stopPolicy, observations: observations)
        operations = Operations(configure: { try await adapter.configure() },
            start: { try await adapter.start(url) },
            append: { sample in
                switch sample.kind {
                case .video: await adapter.video(sample.sampleBuffer)
                case .audio:
                    guard let (pcm, when) = copyPCM(sample.sampleBuffer) else { throw PublisherError.invalidSample }
                    await adapter.audio(pcm, when: when)
                }
            }, isPublishing: { await adapter.isPublishing() }, stop: { await adapter.stop() },
            setBitRate: { try await adapter.setBitRate($0) }, metrics: { await adapter.metrics() })
    }

    struct Operations: Sendable {
        let configure: @Sendable () async throws -> Void
        let start: @Sendable () async throws -> Void
        let append: @Sendable (CapturedMediaSample) async throws -> Void
        let isPublishing: @Sendable () async -> Bool
        let stop: @Sendable () async -> Void
        let setBitRate: @Sendable (Int) async throws -> Void
        let metrics: @Sendable () async -> TransportMetrics?
    }
    init(operations: Operations) { self.operations = operations }

    public func start() async throws {
        guard state == .prepared else { throw PublisherError.invalidState }
        state = .starting
        let attempt = Task { try await self.performStartup() }
        startup = attempt
        do {
            try await attempt.value
            startup = nil
            try checkStarting()
            state = .publishing
        } catch {
            startup = nil
            let reason: PublisherError = state == .stopped || error is CancellationError
                ? .cancelled : (error as? PublisherError ?? .startFailed)
            await stop()
            throw reason
        }
    }

    public func append(_ sample: CapturedMediaSample) async throws {
        guard state == .publishing else { throw PublisherError.notPublishing }
        do {
            try Task.checkCancellation()
            try await operations.append(sample)
            guard state == .publishing else { throw PublisherError.cancelled }
        } catch is CancellationError { throw PublisherError.cancelled }
        catch let error as PublisherError {
            throw error
        }
        catch { throw PublisherError.appendFailed }
    }

    public var isPublishing: Bool {
        get async {
            guard state == .publishing else { return false }
            let healthy = await operations.isPublishing()
            return state == .publishing && healthy
        }
    }

    public func stop() async {
        state = .stopped
        let pending: Task<Void, Never>
        if let shutdown { pending = shutdown }
        else {
            let close = operations.stop
            let starting = startup
            starting?.cancel()
            pending = Task.detached {
                // Close first so a blocked configure/connect/readiness operation
                // can finish. The reusable SDK can reopen on a late actor hop;
                // join that operation and close again before shutdown completes.
                await close()
                if let starting {
                    _ = await starting.result
                    await close()
                }
            }
            shutdown = pending
        }
        await pending.value
    }

    public func setBitRate(_ bitsPerSecond: Int) async throws {
        guard state == .publishing else { throw PublisherError.notPublishing }
        guard !Task.isCancelled else { throw PublisherError.cancelled }
        guard !bitRateUpdating else { throw PublisherError.invalidState }
        bitRateUpdating = true
        defer { bitRateUpdating = false }
        do { try await operations.setBitRate(bitsPerSecond) }
        catch {
            if state == .stopped || Task.isCancelled {
                // A dispatched operation may already have changed native settings.
                // Join live shutdown rather than leave an abandoned change active.
                await stop()
                throw PublisherError.cancelled
            }
            throw PublisherError.bitRateUpdateFailed
        }
        guard state == .publishing else { throw PublisherError.cancelled }
        if Task.isCancelled {
            await stop()
            throw PublisherError.cancelled
        }
    }

    public func metrics() async -> TransportMetrics? {
        guard state == .publishing else { return nil }
        let metrics = await operations.metrics()
        return state == .publishing ? metrics : nil
    }

    private func performStartup() async throws {
        try checkStarting()
        try await operations.configure()
        try checkStarting()
        try await operations.start()
        try checkStarting()
        let healthy = await operations.isPublishing()
        try checkStarting()
        guard healthy else { throw PublisherError.notPublishing }
    }

    private func checkStarting() throws {
        guard state == .starting else { throw PublisherError.cancelled }
        try Task.checkCancellation()
    }
}
