import Foundation

/// An absolute attempt deadline, independent of URLRequest's inactivity timeout.
/// Each call owns and joins its HTTP/deadline children before returning. A slow
/// cancellation join may exceed the budget; it never authorizes an overlapping
/// retry or establishes whether an uncertain mutation committed.
public struct MatchHTTPDeadlineTransport: Sendable {
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    private let timeout: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleeper
    private let transport: MatchHTTPClient.Transport

    public init(timeout: TimeInterval = 2,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: Sleeper? = nil,
                transport: @escaping MatchHTTPClient.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.timeout = timeout; self.now = now
        self.sleep = sleep ?? Self.defaultSleep; self.transport = transport
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let start = now(), deadline = start + timeout
        guard timeout.isFinite, timeout > 0, start.isFinite, deadline.isFinite,
              deadline > start else { throw URLError(.timedOut) }
        var bounded = request
        bounded.timeoutInterval = request.timeoutInterval.isFinite && request.timeoutInterval > 0
            ? min(request.timeoutInterval, timeout) : timeout
        let outgoing = bounded
        do {
            let response = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    let response = try await transport(outgoing)
                    try Task.checkCancellation()
                    // The timer may be delayed. An HTTP response outside the
                    // absolute interval cannot win merely by running first.
                    let time = now()
                    guard time.isFinite, time >= start, time < deadline else { throw URLError(.timedOut) }
                    return HTTPResponse(data: response.0, response: response.1)
                }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        let time = now()
                        guard time.isFinite, time >= start, time < deadline else { throw URLError(.timedOut) }
                        try await sleep(deadline - time)
                    }
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw URLError(.timedOut) }
                return first
                // Task-group scope joins all children, even after cancellation
                // and even when the first terminal result is an error.
            }
            try Task.checkCancellation()
            return (response.data, response.response)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private struct HTTPResponse: Sendable {
        let data: Data
        let response: URLResponse
    }

    private static let defaultSleep: Sleeper = { delay in
        // The deadline loop handles early wakes/chunks. Bound conversion rather
        // than trapping on an unusually large but finite configured timeout.
        try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000))
    }
}
