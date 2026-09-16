import Foundation
import HaishinKit
import libsrt
import Logboard

// libSRT cleanup is process-global: per-connection cleanup invalidates other live sockets.
// Keep initialization process-scoped; individual socket lifetimes still close descriptors.
enum SRTRuntime {
    static let started: Int32 = srt_startup()
}

final actor SRTSocket {
    static let payloadSize: Int = 1316

    enum Error: Swift.Error {
        case notConnected
        case rejected(_ reason: SRTRejectReason)
        case illegalState(_ message: String)
    }

    enum Status: Int, CustomDebugStringConvertible {
        case unknown
        case `init`
        case opened
        case listening
        case connecting
        case connected
        case broken
        case closing
        case closed
        case nonexist

        var debugDescription: String {
            switch self {
            case .unknown:
                return "unknown"
            case .`init`:
                return "init"
            case .opened:
                return "opened"
            case .listening:
                return "listening"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .broken:
                return "broken"
            case .closing:
                return "closing"
            case .closed:
                return "closed"
            case .nonexist:
                return "nonexist"
            }
        }

        init?(_ status: SRT_SOCKSTATUS) {
            self.init(rawValue: Int(status.rawValue))
            defer {
                logger.trace(debugDescription)
            }
        }
    }

    var inputs: AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            // If Task.detached is not used, closing will result in a deadlock.
            Task.detached {
                while await self.connected {
                    let result = await self.recvmsg()
                    if 0 <= result {
                        continuation.yield(await self.incomingBuffer.subdata(in: 0..<Data.Index(result)))
                    } else {
                        await self.stopRunning()
                        continuation.finish()
                    }
                }
            }
        }
    }

    var performanceData: SRTPerformanceData {
        .init(mon: perf, sampledAt: performanceSampledAt)
    }

    var status: Status {
        if let statusProvider { return statusProvider() }
        if sender != nil, isRunning { return .connected }
        return .init(srt_getsockstate(socket)) ?? .unknown
    }

    private(set) var isRunning = false
    private var perf: CBytePerfMon = .init()
    private var performanceSampledAt: TimeInterval?
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var sendingGeneration: UInt64?
    private let maxPayloadBytes: Int
    private let sender: (@Sendable (Data) -> Int32)?
    private let statusProvider: (@Sendable () -> Status)?
    private let statisticsReader: @Sendable (SRTSOCKET, inout CBytePerfMon, Int32) -> Int32
    private var generation: UInt64 = 0
    private let failure = PublishingFailureLatch()
    var publishingError: PublishingError? { failure.error }
    var failureEvents: AsyncStream<PublishingError> { failure.events }
    private var connected: Bool {
        status == .connected
    }
    private var windowSizeC: Int32 = 1024 * 4
    private lazy var incomingBuffer: Data = .init(count: Int(windowSizeC))

    init(maxPayloadBytes: Int = 2 * 1024 * 1024 + 64 * 1024,
         sender: (@Sendable (Data) -> Int32)? = nil, statusProvider: (@Sendable () -> Status)? = nil,
         statisticsReader: @escaping @Sendable (SRTSOCKET, inout CBytePerfMon, Int32) -> Int32 = { srt_bstats($0, &$1, $2) }) {
        precondition(maxPayloadBytes > 0)
        self.maxPayloadBytes = maxPayloadBytes
        self.sender = sender
        self.statusProvider = statusProvider
        self.statisticsReader = statisticsReader
        _ = SRTRuntime.started
        socket = srt_create_socket()
    }

    init(socket: SRTSOCKET, options: [SRTSocketOption]) async throws {
        self.maxPayloadBytes = 2 * 1024 * 1024 + 64 * 1024
        self.sender = nil
        self.statusProvider = nil
        self.statisticsReader = { srt_bstats($0, &$1, $2) }
        self.socket = socket
        guard configure(options, restriction: .post) else {
            throw makeSocketError()
        }
        try enforceTimeouts(includeConnect: false)
        if incomingBuffer.count < windowSizeC {
            incomingBuffer = .init(count: Int(windowSizeC))
        }
    }

    deinit {
        if socket != SRT_INVALID_SOCK { srt_close(socket) }
    }

    func getSocketOption(_ name: SRTSocketOption.Name) throws -> SRTSocketOption {
        return try SRTSocketOption(name: name, socket: socket)
    }

    func setSocketOption(_ option: SRTSocketOption) throws {
        if ["conntimeo", "sndtimeo", "rcvtimeo"].contains(option.name.rawValue) {
            let limit = option.name.rawValue == "conntimeo" ? 3000 : 500
            guard option.intValue > 0 && option.intValue <= limit else { throw Error.illegalState("Timeout exceeds publishing bound") }
        }
        try option.setSockflag(socket)
    }

    func enforceTimeouts(includeConnect: Bool = true) throws {
        let names: [SRTSocketOption.Name] = includeConnect ? [.conntimeo, .sndtimeo, .rcvtimeo] : [.sndtimeo, .rcvtimeo]
        for name in names {
            let cap = name.rawValue == "conntimeo" ? 3000 : 500
            let current = try getSocketOption(name).intValue
            try SRTSocketOption(name: name, value: current > 0 ? min(current, cap) : cap).setSockflag(socket)
        }
    }

    func open(_ url: SRTSocketURL) async throws {
        if sender != nil { await startRunning(); return }
        if socket == SRT_INVALID_SOCK {
            throw makeSocketError()
        }
        guard configure(url.options, restriction: .pre) else {
            throw makeSocketError()
        }
        try enforceTimeouts()
        let status: Int32 = try {
            switch url.mode {
            case .caller:
                guard var remote = url.remote else {
                    return SRT_ERROR
                }
                var remoteaddr = remote.makeSockaddr()
                return srt_connect(socket, &remoteaddr, Int32(remote.size))
            case .listener:
                guard var local = url.local else {
                    return SRT_ERROR
                }
                var localaddr = local.makeSockaddr()
                let status = srt_bind(socket, &localaddr, Int32(local.size))
                guard status != SRT_ERROR else {
                    throw makeSocketError()
                }
                return srt_listen(socket, 1)
            case .rendezvous:
                guard var remote = url.remote, var local = url.local else {
                    return SRT_ERROR
                }
                var remoteaddr = remote.makeSockaddr()
                var localaddr = local.makeSockaddr()
                return srt_rendezvous(socket, &remoteaddr, Int32(remote.size), &localaddr, Int32(local.size))
            }
        }()
        guard status != SRT_ERROR else {
            let reason = SRTRejectReason(socket: socket) ?? .unknown
            throw Error.rejected(reason)
        }
        switch url.mode {
        case .listener:
            break
        default:
            guard configure(url.options, restriction: .post) else {
                throw makeSocketError()
            }
            try enforceTimeouts(includeConnect: false)
            if incomingBuffer.count < windowSizeC {
                incomingBuffer = .init(count: Int(windowSizeC))
            }
        }
        await startRunning()
    }

    func accept(_ options: [SRTSocketOption]) async throws -> SRTSocket {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SRTSocket, Swift.Error>) in
            Task.detached { [self] in
                do {
                    let accept = srt_accept(await socket, nil, nil)
                    guard -1 < accept else {
                        throw await makeSocketError()
                    }
                    let socket = try await SRTSocket(socket: accept, options: options)
                    await socket.startRunning()
                    continuation.resume(returning: socket)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One bounded payload at a time. The existing transport consumer awaits
    /// acceptance, so a normal startup burst cannot outrun a second socket queue.
    func send(_ data: Data) async throws {
        guard isRunning, connected || sender != nil else { throw Error.notConnected }
        if let error = failure.error { throw error }
        guard data.count <= maxPayloadBytes else {
            let error = PublishingError.itemSizeExceeded(boundary: "SRT socket", bytes: data.count, limit: maxPayloadBytes)
            failure.fail(error)
            throw error
        }
        guard sendingGeneration == nil else {
            let error = PublishingError.queueCapacityExceeded(boundary: "SRT socket concurrent send")
            failure.fail(error)
            throw error
        }
        let session = generation
        sendingGeneration = session
        defer { if sendingGeneration == session { sendingGeneration = nil } }
        do {
            for offset in stride(from: 0, to: data.count, by: Self.payloadSize) {
                try Task.checkCancellation()
                guard isRunning, generation == session else { throw Error.notConnected }
                if let error = failure.error { throw error }
                let chunk = data.subdata(in: offset..<min(offset + Self.payloadSize, data.count))
                guard sendmsg(chunk) == chunk.count else {
                    failure.fail(.transportWriteFailed)
                    await stopRunning()
                    throw PublishingError.transportWriteFailed
                }
                // Every synchronous libsrt send has a finite timeout. Yield after
                // each datagram so close never waits behind a whole large payload.
                await Task.yield()
            }
            try Task.checkCancellation()
            guard isRunning, generation == session else { throw Error.notConnected }
            if let error = failure.error { throw error }
        } catch is CancellationError {
            failure.fail(.outputTerminated(boundary: "SRT socket cancelled send"))
            await stopRunning()
            throw CancellationError()
        }
    }

    /// Optional one-message write, serialized with media and never waiting for
    /// send-buffer space. The shared permit rechecks revocation after actor hops.
    func sendPadding(_ probe: SRTBandwidthProbe, pendingMedia: TransportOutputAccounting) throws {
        guard isRunning, connected, failure.error == nil, !Task.isCancelled else {
            probe.cancel(.closed); return
        }
        guard sendingGeneration == nil,
              probe.isEligible(now: { ProcessInfo.processInfo.systemUptime }) else { return }
        let statistics = samplePerformanceData()
        do {
            try pendingMedia.whileEmpty {
                try probe.offer(statistics: statistics, now: { ProcessInfo.processInfo.systemUptime }) { message in
                    try SRTNonblockingSend.perform(get: {
                        var value = false
                        var size = Int32(MemoryLayout<Bool>.size)
                        guard srt_getsockflag(socket, SRTO_SNDSYN, &value, &size) == 0,
                              size == MemoryLayout<Bool>.size else { throw PublishingError.transportWriteFailed }
                        return value
                    }, set: { value in
                        var value = value
                        guard srt_setsockflag(socket, SRTO_SNDSYN, &value, Int32(MemoryLayout<Bool>.size)) == 0 else {
                            throw PublishingError.transportWriteFailed
                        }
                    }, send: {
                        let sent = sendmsg(message)
                        if sent == message.count { return true }
                        // Capture the native thread-local error before restoring an option.
                        if sent == SRT_ERROR, srt_getlasterror(nil) == SRT_EASYNCSND.rawValue { return false }
                        throw PublishingError.transportWriteFailed
                    })
                }
            }
        } catch {
            failure.fail(.transportWriteFailed)
            throw PublishingError.transportWriteFailed
        }
    }

    private func configure(_ options: [SRTSocketOption], restriction: SRTSocketOption.Restriction) -> Bool {
        var failures: [String] = []
        for option in options where option.name.restriction == restriction {
            do {
                try option.setSockflag(socket)
            } catch {
                failures.append(option.name.rawValue)
            }
        }
        guard failures.isEmpty else {
            logger.error(failures)
            return false
        }
        return true
    }

    func collectPerformanceData(using read: (inout CBytePerfMon) -> Int32,
                                now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Int32 {
        guard socket != SRT_INVALID_SOCK else { performanceSampledAt = nil; return SRT_ERROR }
        // Sampling at entry includes native-call time in subsequent sample age.
        // A failed call cannot retimestamp old counters or commit partial output.
        let sampledAt = now()
        var next = perf
        let result = read(&next)
        if result == 0 {
            perf = next
            performanceSampledAt = sampledAt.isFinite && sampledAt >= 0 ? sampledAt : nil
        } else { performanceSampledAt = nil }
        return result
    }

    func samplePerformanceData() -> SRTPerformanceData? {
        guard isRunning, connected, !Task.isCancelled else { return nil }
        let currentSocket = socket
        // Demand observations do not reset the bandwidth monitor's interval data.
        guard collectPerformanceData(using: { statisticsReader(currentSocket, &$0, 0) }) == 0,
              !Task.isCancelled else { return nil }
        return performanceData
    }

    private func bstats() -> Int32 {
        let currentSocket = socket
        return collectPerformanceData { statisticsReader(currentSocket, &$0, 1) }
    }

    private func makeSocketError() -> Error {
        let error_message = String(cString: srt_getlasterror_str())
        defer {
            logger.error(error_message)
        }
        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }
        return .illegalState(error_message)
    }

    @inline(__always)
    private func sendmsg(_ data: Data) -> Int32 {
        if let sender { return sender(data) }
        return data.withUnsafeBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_sendmsg(socket, buffer, Int32(data.count), -1, 0)
        }
    }

    @inline(__always)
    private func recvmsg() -> Int32 {
        return incomingBuffer.withUnsafeMutableBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_recvmsg(socket, buffer, windowSizeC)
        }
    }
}

extension SRTSocket: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() async {
        guard !isRunning, failure.error == nil else { return }
        generation &+= 1
        isRunning = true
    }

    func stopRunning() async {
        performanceSampledAt = nil
        generation &+= 1
        isRunning = false
        sendingGeneration = nil
        failure.finish()
        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }
    }
}

extension SRTSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkTransportReport() -> NetworkTransportReport {
        let result = bstats()
        if isRunning {
            switch status {
            case .broken, .closing, .closed, .nonexist:
                failure.fail(.transportWriteFailed)
            case .connected where result == SRT_ERROR && sender == nil:
                failure.fail(.transportWriteFailed)
            default: break
            }
        }
        let performanceData = self.performanceData
        return .init(
            queueBytesOut: Int(performanceData.byteSndBuf),
            totalBytesIn: Int(performanceData.byteRecvTotal),
            totalBytesOut: Int(performanceData.byteSentTotal)
        )
    }

    func makeNetworkMonitor() -> NetworkMonitor {
        return .init(self)
    }
}
