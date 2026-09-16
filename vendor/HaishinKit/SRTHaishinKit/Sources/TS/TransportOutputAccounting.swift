import Foundation

/// One muxer-output generation. Linearizes media admission with the optional
/// nonblocking write; an empty-queue observation cannot go stale across actors.
final class TransportOutputAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var pending: Int { lock.withLock { count } }
    func enqueue(_ yield: () -> Bool) -> Bool {
        lock.withLock {
            guard count < Int.max, yield() else { return false }
            count += 1; return true
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
