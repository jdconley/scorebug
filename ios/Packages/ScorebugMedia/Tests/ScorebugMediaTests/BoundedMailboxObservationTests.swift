import CoreMedia
import Foundation
import Testing
@testable import ScorebugMedia

struct BoundedMailboxObservationTests {
    private func mailbox(items: Int = 2, bytes: Int = 100) throws -> BoundedMailbox<Int> {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let box = try BoundedMailbox<Int>(maxItems: items, maxBytes: bytes, overflowPolicy: .dropOldest,
            ingressObservation: .init(scope: scope, monotonicAnchor: 0))
        box.setObservationTimeForTesting(0)
        return box
    }
    private func sample(_ kind: LiveIngressSampleKind, _ value: Int64) -> LiveIngressSampleMetadata {
        .init(kind: kind, sourcePTS: CMTime(value: value, timescale: 30))
    }
    private func near(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.000001) }

    @Test func actualMutationsIntegrateItemByteAndMaximumPressure() async throws {
        let box = try mailbox()
        #expect(box.offer(1, bytes: 25, observation: sample(.video, 10)).acceptedCount == 1)
        box.setObservationTimeForTesting(2)
        #expect(box.offer(2, bytes: 75, observation: sample(.audio, 20)).acceptedCount == 1)
        box.setObservationTimeForTesting(3)
        #expect(try await box.next() == 1)
        box.setObservationTimeForTesting(5)
        let snapshot = box.snapshot
        let ingress = try #require(snapshot.ingressObservation)
        #expect(snapshot.statistics.currentItems == 1)
        #expect(snapshot.statistics.currentBytes == 75)
        let window = try #require(ingress.completed.first)
        near(window.occupancy.itemSeconds, 3)
        near(window.occupancy.byteSeconds, 3)
        near(window.occupancy.maxPressureSeconds, 3.5)
        near(try #require(window.occupancy.meanMaxPressure), 0.7)
        #expect(ingress.totalDispositions[.admitted]?[.video]?.count == 1)
        #expect(ingress.totalDispositions[.admitted]?[.audio]?.count == 1)
        #expect(ingress.totalDispositions[.dequeued]?[.video]?.minimumSourcePTS?.value == 10)
        box.cancel()
    }

    @Test func directHandoffNeverInflatesQueuedPressure() async throws {
        let box = try mailbox(items: 1)
        let waiting = Task { try await box.next() }
        try await waitForConsumer(box)
        box.setObservationTimeForTesting(1)
        box.offer(7, bytes: 100, observation: sample(.video, 7))
        #expect(try await waiting.value == 7)
        box.setObservationTimeForTesting(5)
        let s = try #require(box.snapshot.ingressObservation)
        near(s.totalOccupancy.maxPressureSeconds, 0)
        #expect(s.totalDispositions[.admitted]?[.video]?.count == 1)
        #expect(s.totalDispositions[.dequeued]?[.video]?.count == 1)
        #expect(box.statistics.currentItems == 0)
        box.cancel()
    }

    @Test func evictionsRetainRemovedKindsAndShutdownDiscardsStaySeparate() throws {
        let box = try mailbox(items: 3, bytes: 10)
        box.offer(0, bytes: 3, observation: sample(.video, 0))
        box.offer(1, bytes: 3, observation: sample(.audio, 1))
        box.offer(2, bytes: 3, observation: sample(.video, 2))
        box.setObservationTimeForTesting(2)
        let admission = box.offer(3, bytes: 7, observation: sample(.audio, 3))
        #expect(admission.droppedCount == 2)
        box.setObservationTimeForTesting(3)
        #expect(box.offer(4, bytes: 11, observation: sample(.video, 4)).rejectionReason == .oversize)
        #expect(box.statistics.currentBytes == 10)
        box.setObservationTimeForTesting(6)
        box.cancel()
        let s = try #require(box.snapshot.ingressObservation)
        #expect(s.isClosed)
        #expect(s.totalDispositions[.overflowEvicted]?[.video]?.minimumSourcePTS?.value == 0)
        #expect(s.totalDispositions[.overflowEvicted]?[.audio]?.minimumSourcePTS?.value == 1)
        #expect(s.totalDispositions[.cancellationDiscarded]?[.video]?.minimumSourcePTS?.value == 2)
        #expect(s.totalDispositions[.cancellationDiscarded]?[.audio]?.minimumSourcePTS?.value == 3)
        #expect(s.totalDispositions[.rejected(.oversize)]?[.video]?.count == 1)
        #expect(box.statistics.droppedCount == 4)
        box.setObservationTimeForTesting(1000)
        box.cancel()
        #expect(box.offer(5, bytes: 1).rejectionReason == .cancelled)
        let late = try #require(box.snapshot.ingressObservation)
        #expect(late.current.monotonicEnd == s.current.monotonicEnd)
        near(late.totalOccupancy.maxPressureSeconds, s.totalOccupancy.maxPressureSeconds)
    }

    @Test func finishMeasuresDrainAndWaitingTaskCancellationDoesNotClose() async throws {
        let box = try mailbox()
        let waiting = Task { try await box.next() }
        try await waitForConsumer(box)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(box.snapshot.ingressObservation?.isClosed == false)
        box.setObservationTimeForTesting(1)
        box.offer(1, bytes: 100, observation: sample(.audio, 1))
        box.setObservationTimeForTesting(2)
        box.finish()
        #expect(box.snapshot.ingressObservation?.phase == .draining)
        #expect(box.offer(2, bytes: 1, observation: sample(.video, 2)).rejectionReason == .finished)
        box.setObservationTimeForTesting(4)
        #expect(try await box.next() == 1)
        let s = try #require(box.snapshot.ingressObservation)
        #expect(s.isClosed)
        near(s.totalOccupancy.maxPressureSeconds, 3)
        #expect(s.totalDispositions[.rejected(.finished)]?[.video]?.count == 1)
        #expect(s.totalDispositions[.cancellationDiscarded] == nil)
        #expect(try await box.next() == nil)
    }

    @Test func invalidClockDoesNotChangeAdmissionOrInventKnownEmptyTime() async throws {
        let box = try mailbox(items: 1)
        box.offer(1, bytes: 100, observation: sample(.video, 1))
        box.setObservationTimeForTesting(.nan)
        #expect(box.offer(2, bytes: 50, observation: sample(.audio, 2)).droppedCount == 1)
        #expect(box.statistics.currentItems == 1)
        box.setObservationTimeForTesting(5)
        let s = try #require(box.snapshot.ingressObservation)
        #expect(s.invalidity.contains(.invalidMonotonicClock))
        #expect(s.totalDispositions[.overflowEvicted]?[.video]?.count == 1)
        #expect(s.totalDispositions[.admitted]?[.audio]?.count == 1)
        near(s.totalOccupancy.knownDuration, 0)
        #expect(try await box.next() == 2)
        box.cancel()
    }

    @Test func malformedDiagnosticsDoNotFailMailboxAndDefaultRemainsAbsent() throws {
        let scope = VideoFrameObservationScope(recordingID: "r", matchID: "m", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let malformed = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 2, overflowPolicy: .rejectNew,
            ingressObservation: .init(scope: scope, monotonicAnchor: .nan))
        let plain = try BoundedMailbox<Int>(maxItems: 1, maxBytes: 2, overflowPolicy: .rejectNew)
        for box in [malformed, plain] {
            #expect(box.offer(1, bytes: 2).acceptedCount == 1)
            #expect(box.offer(2, bytes: 1).rejectionReason == .full)
            #expect(box.snapshot.ingressObservation == nil)
            box.cancel()
        }
    }

    @Test func concurrentConsumersSnapshotsAndCancellationKeepAccountingConsistent() async throws {
        let box = try mailbox(items: 4, bytes: 7)
        let consumer = Task { () throws -> [Int] in
            var received: [Int] = []
            while let value = try await box.next() { received.append(value) }
            return received
        }
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for i in 0..<100 {
                        box.offer(producer * 100 + i, bytes: 2, observation: sample(.video, Int64(i)))
                        let s = box.snapshot
                        #expect(s.statistics.currentItems <= 4)
                        #expect(s.statistics.currentBytes <= 7)
                        #expect(s.ingressObservation?.currentItems == s.statistics.currentItems)
                        #expect(s.ingressObservation?.currentBytes == s.statistics.currentBytes)
                    }
                }
            }
        }
        box.finish()
        let received = try await consumer.value
        let s = box.snapshot
        let totals = try #require(s.ingressObservation).totalDispositions
        #expect(s.statistics.acceptedCount == 400)
        #expect(totals[.admitted]?[.video]?.count == 400)
        #expect(totals[.dequeued]?[.video]?.count == UInt64(received.count))
        #expect(s.statistics.droppedCount + received.count == 400)
        #expect(s.ingressObservation?.isClosed == true)
    }

    @Test func racingCancellationFreezesConservedCountsWithoutRetainingLateOffers() async throws {
        let box = try mailbox(items: 4, bytes: 7)
        box.offer(-1, bytes: 2, observation: sample(.video, 0))
        let consumer = Task { () throws -> Int in
            var count = 0
            while try await box.next() != nil { count += 1 }
            return count
        }
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for i in 0..<100 {
                        box.offer(producer * 100 + i, bytes: 2, observation: sample(.video, Int64(i)))
                        let s = box.snapshot
                        #expect(s.ingressObservation?.currentItems == s.statistics.currentItems)
                        #expect(s.ingressObservation?.currentBytes == s.statistics.currentBytes)
                    }
                }
            }
            group.addTask { box.cancel() }
        }
        let received = try await consumer.value
        let s = box.snapshot
        let ingress = try #require(s.ingressObservation)
        let t = ingress.totalDispositions
        let accepted = t[.admitted]?[.video]?.count ?? 0
        let dequeued = t[.dequeued]?[.video]?.count ?? 0
        let overflow = t[.overflowEvicted]?[.video]?.count ?? 0
        let discarded = t[.cancellationDiscarded]?[.video]?.count ?? 0
        #expect(ingress.isClosed)
        #expect(accepted == dequeued + overflow + discarded)
        #expect(dequeued == UInt64(received))
        #expect(accepted == UInt64(s.statistics.acceptedCount))
        #expect(overflow + discarded == UInt64(s.statistics.droppedCount))
        #expect(s.statistics.acceptedCount + s.statistics.rejectedCount == 401)
    }

    private func waitForConsumer(_ box: BoundedMailbox<Int>) async throws {
        for _ in 0..<10_000 {
            if box.statistics.hasPendingConsumer { return }
            await Task.yield()
        }
        box.cancel()
        throw WaitFailure.timeout
    }
    private enum WaitFailure: Error { case timeout }
}
