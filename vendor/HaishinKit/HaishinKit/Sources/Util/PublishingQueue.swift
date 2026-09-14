import Foundation

/// A terminal failure of a named publishing boundary. No compressed media is silently dropped.
public enum PublishingError: Swift.Error, Equatable, Sendable {
    case queueCapacityExceeded(boundary: String)
    case itemSizeExceeded(boundary: String, bytes: Int, limit: Int)
    case outputTerminated(boundary: String)
    case codecFailed(status: Int32)
    case muxerFailed(reason: String)
    case transportWriteFailed
}

/// One event per session, synchronously latched even from VideoToolbox callbacks.
package final class PublishingFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: PublishingError?
    package let events: AsyncStream<PublishingError>
    private let continuation: AsyncStream<PublishingError>.Continuation

    package init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    }

    package var error: PublishingError? { lock.withLock { storedError } }

    package func fail(_ error: PublishingError) {
        lock.withLock {
            guard storedError == nil else { return }
            storedError = error
            continuation.yield(error)
            continuation.finish()
        }
    }

    package func finish() { continuation.finish() }
}

/// Count bound plus an independent pre-yield byte limit. Limits cover retained queue items,
/// not VideoToolbox/AVAudioConverter/libSRT internal allocations or producer-owned input.
package final class PublishingQueue<Element: Sendable>: @unchecked Sendable {
    package struct Limits: Sendable {
        package var count: Int
        package var bytesPerItem: Int
        package init(count: Int, bytesPerItem: Int) {
            precondition(count > 0 && bytesPerItem > 0)
            self.count = count
            self.bytesPerItem = bytesPerItem
        }
    }

    package let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let lock = NSLock()
    private var finished = false
    private let boundary: String
    private let limits: Limits
    private let failure: PublishingFailureLatch

    package init(boundary: String, limits: Limits, failure: PublishingFailureLatch) {
        self.boundary = boundary
        self.limits = limits
        self.failure = failure
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(limits.count))
    }

    @discardableResult package func yield(_ element: Element, byteCount: Int) -> Bool {
        lock.withLock {
            guard !finished, failure.error == nil else { return false }
            guard byteCount >= 0, byteCount <= limits.bytesPerItem else {
                terminate(.itemSizeExceeded(boundary: boundary, bytes: byteCount, limit: limits.bytesPerItem))
                return false
            }
            switch continuation.yield(element) {
            case .enqueued: return true
            case .dropped: terminate(.queueCapacityExceeded(boundary: boundary))
            case .terminated: terminate(.outputTerminated(boundary: boundary))
            @unknown default: terminate(.outputTerminated(boundary: boundary))
            }
            return false
        }
    }

    package func fail(_ error: PublishingError) {
        lock.withLock {
            guard !finished else { return }
            terminate(error)
        }
    }

    package func finish() {
        lock.withLock {
            finished = true
            continuation.finish()
        }
    }

    private func terminate(_ error: PublishingError) {
        finished = true
        failure.fail(error)
        continuation.finish()
    }
}
