import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a SRT connection.
///
/// Supports a one-to-one connection. Multiple connections cannot be established.
public actor SRTConnection: NetworkConnection {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The uri isn’t supported.
        case unsupportedUri(_ uri: URL?)
        /// The failed to connect.
        case failedToConnect(_ reason: SRTRejectReason)
    }

    /// The SRT Library version.
    public static let version: String = SRT_VERSION_STRING
    /// The URI passed to the `connect()` method.
    public private(set) var uri: URL?
    /// This instance connect to server(true) or not(false)
    @Published public private(set) var connected = false
    /// The performance data.
    public var performanceData: SRTPerformanceData? {
        get async {
            return await socket?.performanceData
        }
    }

    /// Collects current native statistics without resetting interval counters.
    /// A close, replacement or cancellation during collection discards the result.
    public func samplePerformanceData() async -> SRTPerformanceData? {
        guard connected, !closing, !Task.isCancelled, let activeSocket = socket else { return nil }
        let session = generation
        let sample = await activeSocket.samplePerformanceData()
        guard generation == session, socket === activeSocket, connected, !closing,
              !Task.isCancelled else { return nil }
        return sample
    }

    /// First terminal publishing failure; reset on a new connect attempt.
    @Published public private(set) var publishingError: PublishingError?
    private var generation: UInt64 = 0
    private var closing = false
    private var failureTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var socket: SRTSocket?
    private var streams: [SRTStream] = []
    private var listener: SRTSocket?
    private var networkMonitor: NetworkMonitor?

    /// Creates an object.
    public init() {
        socket = SRTSocket()
    }

    init(socket: SRTSocket) {
        self.socket = socket
    }

    deinit {
        streams.removeAll()
    }

    /// Gets a SRTSocketOption.
    public func getSocketOption(_ name: SRTSocketOption.Name) async throws -> SRTSocketOption? {
        try await socket?.getSocketOption(name)
    }

    /// Sets a SRTSocketOption.
    public func setSocketOption(_ option: SRTSocketOption) async throws {
        if connected {
            guard option.name.restriction == .post else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        } else {
            guard option.name.restriction == .pre else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        }
    }

    /// Creates a connection to the server or waits for an incoming connection.
    ///
    /// - Parameters:
    ///   - uri: You can specify connection options in the URL. This follows the standard SRT format.
    ///
    /// - srt://192.168.1.1:9000?mode=caller
    ///   - Connect to the specified server.
    /// - srt://:9000?mode=listener
    ///   - Wait for connections as a server.
    public func connect(_ uri: URL?) async throws {
        guard let url = SRTSocketURL(uri) else {
            throw Error.unsupportedUri(uri)
        }
        guard !closing, !connected, self.uri == nil else { throw Error.invalidState }
        generation &+= 1
        let session = generation
        publishingError = nil
        self.uri = uri
        let openingSocket = socket ?? SRTSocket()
        socket = openingSocket
        do {
            try await openingSocket.open(url)
            guard generation == session else {
                await openingSocket.stopRunning()
                throw Error.invalidState
            }
            if url.mode == .listener {
                listener = openingSocket
                let accepted = try await openingSocket.accept(url.options)
                guard generation == session else {
                    await accepted.stopRunning()
                    throw Error.invalidState
                }
                socket = accepted
                await openingSocket.stopRunning()
                listener = nil
            }
            guard generation == session, let activeSocket = socket else { throw Error.invalidState }
            connected = await activeSocket.status == .connected
            guard generation == session else { throw Error.invalidState }
            observeFailure(of: activeSocket, generation: session)
            monitorTask = Task {
                let monitor = await activeSocket.makeNetworkMonitor()
                guard generation == session, !Task.isCancelled else { return }
                networkMonitor = monitor
                await monitor.startRunning()
                for await event in await monitor.event {
                    guard generation == session, !Task.isCancelled else { break }
                    for stream in streams { await stream.dispatch(event) }
                }
                await monitor.stopRunning()
            }
        } catch {
            await openingSocket.stopRunning()
            if generation == session {
                self.uri = nil
                connected = false
                socket = SRTSocket()
            }
            if case SRTSocket.Error.rejected(let reason) = error { throw Error.failedToConnect(reason) }
            throw Error.invalidState
        }
    }

    private func observeFailure(of socket: SRTSocket, generation session: UInt64) {
        failureTask?.cancel()
        failureTask = Task {
            for await failure in await socket.failureEvents {
                guard generation == session, !Task.isCancelled else { return }
                await failPublishing(failure, generation: session)
                return
            }
        }
    }

    /// Closes a connection, invalidating session work before awaiting external actors.
    public func close() async {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        generation &+= 1
        connected = false
        uri = nil
        failureTask?.cancel()
        failureTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        let oldMonitor = networkMonitor
        networkMonitor = nil
        let oldSocket = socket
        let oldListener = listener
        socket = SRTSocket()
        listener = nil
        for stream in streams { await stream.close() }
        await oldMonitor?.stopRunning()
        await oldSocket?.stopRunning()
        await oldListener?.stopRunning()
    }

    func publishingSession() -> UInt64? { connected && !closing ? generation : nil }

    func failPublishing(_ failure: PublishingError, generation session: UInt64) async {
        guard generation == session else { return }
        if publishingError == nil { publishingError = failure }
        await close()
    }

    func send(_ data: Data, generation session: UInt64) async {
        guard generation == session else { return }
        do {
            guard connected, let socket else { return }
            try await socket.send(data)
        } catch {
            guard generation == session else { return }
            await failPublishing((error as? PublishingError) ?? .transportWriteFailed, generation: session)
        }
    }

    func recv() {
        let session = generation
        receiveTask?.cancel()
        receiveTask = Task {
            guard let socket else { return }
            for await data in await socket.inputs {
                guard generation == session, !Task.isCancelled else { return }
                await streams.first?.doInput(data)
            }
            guard generation == session else { return }
            await close()
        }
    }

    func addStream(_ stream: SRTStream) {
        guard !streams.contains(where: { $0 === stream }) else {
            return
        }
        streams.append(stream)
    }

    func removeStream(_ stream: SRTStream) {
        if let index = streams.firstIndex(where: { $0 === stream }) {
            streams.remove(at: index)
        }
    }
}
