import Foundation

/// One muxer-output generation. Linearizes media admission with the optional
/// nonblocking write; an empty-queue observation cannot go stale across actors.
final class TransportOutputAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var closed = false
    let wakes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    /// Signals work, never retains media or accumulates optional send credits.
    func wake() { lock.withLock { if !closed { continuation.yield(()) } } }
    func finish() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            continuation.yield(())
            continuation.finish()
        }
    }
    var pending: Int { lock.withLock { count } }
    func enqueue(_ yield: () -> Bool) -> Bool {
        lock.withLock {
            guard !closed, count < Int.max, yield() else { return false }
            count += 1; continuation.yield(()); return true
        }
    }
    func dequeue() -> Bool {
        lock.withLock {
            guard count > 0 else { return false }
            count -= 1; return true
        }
    }
    @discardableResult func whileEmpty<T>(_ operation: () throws -> T) rethrows -> T? {
        try lock.withLock {
            guard count == 0 else { return nil }
            return try operation()
        }
    }
}
