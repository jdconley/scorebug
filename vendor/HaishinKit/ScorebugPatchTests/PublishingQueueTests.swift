import Foundation
import Testing
@testable import HaishinKit

@Suite struct PublishingQueueTests {
    @Test func encoderCallbackFailureFinishesOutputWithoutAnotherFrame() async {
        let failure = PublishingFailureLatch()
        let queue = PublishingQueue<Data>(boundary: "test", limits: .init(count: 1, bytesPerItem: 2), failure: failure)
        queue.fail(.codecFailed(status: -50))
        #expect(failure.error == .codecFailed(status: -50))
        var received = 0
        for await _ in queue.stream { received += 1 }
        #expect(received == 0)
    }

    @Test func capacityFailureIsTerminalAndPreservesAcceptedOrder() async {
        let failure = PublishingFailureLatch()
        let queue = PublishingQueue<Data>(boundary: "test", limits: .init(count: 2, bytesPerItem: 3), failure: failure)
        #expect(queue.yield(Data([1]), byteCount: 1))
        #expect(queue.yield(Data([2]), byteCount: 1))
        #expect(!queue.yield(Data([3]), byteCount: 1))
        #expect(failure.error == .queueCapacityExceeded(boundary: "test"))
        #expect(!queue.yield(Data([4]), byteCount: 1))
        var received: [Data] = []
        for await value in queue.stream { received.append(value) }
        #expect(received == [Data([1]), Data([2])])
        var events: [PublishingError] = []
        for await event in failure.events { events.append(event) }
        #expect(events == [.queueCapacityExceeded(boundary: "test")])
    }

    @Test func perItemLimitAppliesEvenWithWaitingConsumerAndFirstFailureWins() async {
        let failure = PublishingFailureLatch()
        let queue = PublishingQueue<Data>(boundary: "test", limits: .init(count: 1, bytesPerItem: 2), failure: failure)
        #expect(!queue.yield(Data([1, 2, 3]), byteCount: 3))
        failure.fail(.queueCapacityExceeded(boundary: "other"))
        #expect(failure.error == .itemSizeExceeded(boundary: "test", bytes: 3, limit: 2))
        var received = 0
        for await _ in queue.stream { received += 1 }
        #expect(received == 0)
    }

    @Test func stoppedQueueCannotContaminateFreshSession() async {
        let old = PublishingQueue<Data>(boundary: "old", limits: .init(count: 1, bytesPerItem: 2), failure: .init())
        old.finish()
        let freshFailure = PublishingFailureLatch()
        let fresh = PublishingQueue<Data>(boundary: "fresh", limits: .init(count: 1, bytesPerItem: 2), failure: freshFailure)
        #expect(!old.yield(Data([9]), byteCount: 1))
        #expect(fresh.yield(Data([1]), byteCount: 1))
        fresh.finish()
        var received: [Data] = []
        for await value in fresh.stream { received.append(value) }
        #expect(received == [Data([1])])
        #expect(freshFailure.error == nil)
    }
}
