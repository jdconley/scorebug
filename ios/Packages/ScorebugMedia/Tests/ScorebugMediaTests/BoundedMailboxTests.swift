import Foundation
import Testing
@testable import ScorebugMedia

struct BoundedMailboxTests {
    @Test func validatesLimitsAndRejectsWithoutEvicting() async throws {
        #expect(throws: BoundedMailbox<Int>.MailboxError.invalidLimits) {
            try BoundedMailbox<Int>(maxItems: 0, maxBytes: 8, overflowPolicy: .rejectNew)
        }
        #expect(throws: BoundedMailbox<Int>.MailboxError.invalidLimits) {
            try BoundedMailbox<Int>(maxItems: 1, maxBytes: -1, overflowPolicy: .rejectNew)
        }
        let mailbox = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 8, overflowPolicy: .dropOldest)
        #expect(mailbox.offer(1, bytes: 8).acceptedCount == 1)
        for bytes in [0, -1, Int.min] {
            #expect(mailbox.offer(2, bytes: bytes).rejectionReason == .invalidBytes)
        }
        #expect(mailbox.offer(3, bytes: 9).rejectionReason == .oversize)
        #expect(mailbox.statistics.currentItems == 1)
        #expect(mailbox.statistics.currentBytes == 8)
        #expect(mailbox.statistics.rejectedCount == 4)
        #expect(mailbox.statistics.droppedCount == 0)
        #expect(try await mailbox.next() == 1)
    }

    @Test func rejectNewHonorsIndependentItemAndByteLimits() async throws {
        for (items, bytes, elementBytes) in [(2, 100, 1), (100, 8, 4)] {
            let mailbox = try BoundedMailbox<Int>(maxItems: items, maxBytes: bytes, overflowPolicy: .rejectNew)
            #expect(mailbox.offer(1, bytes: elementBytes).acceptedCount == 1)
            #expect(mailbox.offer(2, bytes: elementBytes).acceptedCount == 1)
            let rejected = mailbox.offer(3, bytes: elementBytes)
            #expect(rejected.acceptedCount == 0)
            #expect(rejected.rejectedCount == 1)
            #expect(rejected.droppedCount == 0)
            #expect(rejected.rejectionReason == .full)
            #expect(mailbox.statistics.peakItems == 2)
            #expect(mailbox.statistics.peakBytes == elementBytes * 2)
            #expect(try await mailbox.next() == 1)
            #expect(try await mailbox.next() == 2)
            #expect(mailbox.statistics.currentBytes == 0)
        }
    }

    @Test func dropOldestEvictsEnoughItemsAndPreservesOrder() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 3, maxBytes: 10, overflowPolicy: .dropOldest)
        for index in 1...3 { _ = mailbox.offer(index, bytes: 3) }
        let admission = mailbox.offer(4, bytes: 7)
        #expect(admission.acceptedCount == 1)
        #expect(admission.rejectedCount == 0)
        #expect(admission.droppedCount == 2)
        #expect(mailbox.statistics.currentItems == 2)
        #expect(mailbox.statistics.currentBytes == 10)
        #expect(mailbox.statistics.peakItems == 3)
        #expect(mailbox.statistics.peakBytes == 10)
        #expect(mailbox.statistics.acceptedCount == 4)
        #expect(mailbox.statistics.droppedCount == 2)
        #expect(try await mailbox.next() == 3)
        #expect(try await mailbox.next() == 4)
    }

    @Test func accountingDoesNotOverflowIntMax() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: Int.max, maxBytes: Int.max, overflowPolicy: .dropOldest)
        _ = mailbox.offer(1, bytes: Int.max)
        #expect(mailbox.offer(2, bytes: 1).droppedCount == 1)
        #expect(mailbox.statistics.currentBytes == 1)
        #expect(mailbox.statistics.peakBytes == Int.max)
        #expect(try await mailbox.next() == 2)
    }

    @Test func finishDrainsAndIsIdempotent() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 8, overflowPolicy: .rejectNew)
        _ = mailbox.offer(1, bytes: 4)
        _ = mailbox.offer(2, bytes: 4)
        mailbox.finish()
        mailbox.finish()
        #expect(mailbox.offer(3, bytes: 4).rejectionReason == .finished)
        #expect(try await mailbox.next() == 1)
        #expect(try await mailbox.next() == 2)
        #expect(try await mailbox.next() == nil)
        #expect(try await mailbox.next() == nil)
        #expect(mailbox.statistics.currentItems == 0)
    }

    @Test func pendingConsumerReceivesDirectOfferAndFinish() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 1, overflowPolicy: .rejectNew)
        let consumer = Task { try await mailbox.next() }
        try await waitForConsumer(mailbox)
        #expect(mailbox.offer(7, bytes: 1).acceptedCount == 1)
        #expect(try await consumer.value == 7)
        #expect(mailbox.statistics.currentItems == 0)
        #expect(mailbox.statistics.peakItems == 0)
        let finishingConsumer = Task { try await mailbox.next() }
        try await waitForConsumer(mailbox)
        mailbox.finish()
        #expect(try await finishingConsumer.value == nil)
    }

    @Test func rejectsConcurrentPendingConsumer() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 1, overflowPolicy: .rejectNew)
        let consumer = Task { try await mailbox.next() }
        try await waitForConsumer(mailbox)
        await #expect(throws: BoundedMailbox<Int>.MailboxError.concurrentConsumer) {
            try await mailbox.next()
        }
        mailbox.finish()
        #expect(try await consumer.value == nil)
    }

    @Test func cancelDiscardsQueueAndResumesWaiter() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 8, overflowPolicy: .rejectNew)
        _ = mailbox.offer(1, bytes: 4)
        _ = mailbox.offer(2, bytes: 4)
        mailbox.finish()
        mailbox.cancel()
        mailbox.cancel()
        #expect(mailbox.statistics.currentItems == 0)
        #expect(mailbox.statistics.currentBytes == 0)
        #expect(mailbox.statistics.droppedCount == 2)
        #expect(mailbox.offer(3, bytes: 4).rejectionReason == .cancelled)
        #expect(try await mailbox.next() == nil)
        let waitingMailbox = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 1, overflowPolicy: .rejectNew)
        let consumer = Task { try await waitingMailbox.next() }
        try await waitForConsumer(waitingMailbox)
        waitingMailbox.cancel()
        #expect(try await consumer.value == nil)
    }

    @Test func cancellationBeforeAndDuringWaitLeavesMailboxUsable() async throws {
        let mailbox = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 1, overflowPolicy: .rejectNew)
        let cancelledBefore = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await mailbox.next()
        }
        await #expect(throws: CancellationError.self) { try await cancelledBefore.value }
        let cancelledDuring = Task { try await mailbox.next() }
        try await waitForConsumer(mailbox)
        cancelledDuring.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledDuring.value }
        #expect(!mailbox.statistics.hasPendingConsumer)
        _ = mailbox.offer(9, bytes: 1)
        #expect(try await mailbox.next() == 9)
    }

    @Test func actualRetainedElementsStayBoundedAndReleaseAfterCancel() throws {
        let lifetime = LifetimeCounter()
        let mailbox = try BoundedMailbox<TrackedElement>(maxItems: 3, maxBytes: 7, overflowPolicy: .dropOldest)
        for index in 0..<10_000 {
            _ = mailbox.offer(TrackedElement(index, lifetime: lifetime), bytes: 2)
            #expect(lifetime.count == min(index + 1, 3))
            #expect(mailbox.statistics.currentItems <= 3)
            #expect(mailbox.statistics.currentBytes <= 7)
        }
        mailbox.cancel()
        #expect(lifetime.count == 0)
    }

    @Test func racingProducersCancellationAndFinishStayBounded() async throws {
        for _ in 0..<100 {
            let mailbox = try BoundedMailbox<Int>(maxItems: 4, maxBytes: 7, overflowPolicy: .dropOldest)
            let consumer = Task { try await mailbox.next() }
            await withTaskGroup(of: Void.self) { group in
                for producer in 0..<4 {
                    group.addTask {
                        for index in 0..<100 { _ = mailbox.offer(producer * 100 + index, bytes: 2) }
                    }
                }
                group.addTask { consumer.cancel() }
                group.addTask { mailbox.cancel() }
                group.addTask { mailbox.finish() }
            }
            do { _ = try await consumer.value } catch is CancellationError {} catch { throw error }
            let statistics = mailbox.statistics
            #expect(statistics.currentItems == 0)
            #expect(statistics.currentBytes == 0)
            #expect(statistics.peakItems <= 4)
            #expect(statistics.peakBytes <= 7)
            #expect(statistics.acceptedCount + statistics.rejectedCount == 400)
            #expect(statistics.acceptedCount - statistics.droppedCount <= 1)
            #expect(!statistics.hasPendingConsumer)
            #expect(try await mailbox.next() == nil)
        }
    }

    private func waitForConsumer<T>(_ mailbox: BoundedMailbox<T>) async throws {
        for _ in 0..<10_000 {
            if mailbox.statistics.hasPendingConsumer { return }
            await Task.yield()
        }
        mailbox.cancel()
        throw WaitFailure.consumerDidNotStart
    }

    private enum WaitFailure: Error { case consumerDidNotStart }
}

private final class LifetimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func adjust(_ delta: Int) { lock.withLock { value += delta } }
}

private final class TrackedElement: Sendable {
    let value: Int
    let lifetime: LifetimeCounter
    init(_ value: Int, lifetime: LifetimeCounter) {
        self.value = value
        self.lifetime = lifetime
        lifetime.adjust(1)
    }
    deinit { lifetime.adjust(-1) }
}
