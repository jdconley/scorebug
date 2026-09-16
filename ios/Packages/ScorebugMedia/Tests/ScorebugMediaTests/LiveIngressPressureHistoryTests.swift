import CoreMedia
import Foundation
import Testing
@testable import ScorebugMedia

struct LiveIngressPressureHistoryTests {
    private var scope: VideoFrameObservationScope { .init(recordingID: "r", matchID: "m", broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1) }
    private func make() throws -> LiveIngressObservationAccumulator {
        try .init(scope: scope, monotonicAnchor: 10, maxItems: 4, maxBytes: 100)
    }
    private func near(_ a: Double, _ b: Double) { #expect(abs(a - b) < 1e-9) }
    @Test func integratesFractionalEndpointsAndInstantaneousMaximum() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 10, phase: .admitting, at: 10)
        a.updateOccupancy(items: 1, bytes: 100, at: 12)
        let value = try #require(a.poll(at: 15).pressure.interval(from: 10.5, to: 14.25))
        near(value.itemSeconds, 1.5 + 2.25 * 0.25)
        near(value.byteSeconds, 1.5 * 0.1 + 2.25)
        near(value.maxPressureSeconds, 3.75); near(value.meanMaxPressure, 1)
        #expect(value.start == 10.5); #expect(value.end == 14.25)
    }
    @Test func sameTimeReplacementAndUnchangedPollsDoNotConsumeHistory() throws {
        var a = try make()
        a.updateOccupancy(items: 4, bytes: 100, phase: .admitting, at: 10)
        a.updateOccupancy(items: 0, bytes: 0, at: 10)
        for i in 1...100 { a.poll(at: 10 + Double(i)) }
        let s = a.snapshot.pressure
        #expect(s.states.count == 1); #expect(s.omittedStates == 0)
        near(try #require(s.interval(from: 10, to: 110)).meanMaxPressure, 0)
    }
    @Test func phaseBoundaryExcludesStateAtRightEndpoint() throws {
        var a = try make()
        a.updateOccupancy(items: 2, bytes: 40, phase: .admitting, at: 11)
        a.updateOccupancy(items: 4, bytes: 100, phase: .draining, at: 15)
        let s = a.poll(at: 16).pressure
        #expect(s.interval(from: 10.5, to: 15) == nil)
        near(try #require(s.interval(from: 11, to: 15)).meanMaxPressure, 0.5)
        #expect(s.interval(from: 11, to: 15.1) == nil)
        #expect(s.interval(from: 15, to: 16) == nil)
    }
    @Test func missingCoverageAndMalformedQueriesStayUnknown() throws {
        var a = try make(); a.updateOccupancy(items: 1, bytes: 10, phase: .admitting, at: 10)
        let s = a.poll(at: 15).pressure
        for (start, end) in [(9.0, 12.0), (10, 16), (12, 12), (13, 12), (.nan, 12), (10, .infinity), (-1, 12)] {
            #expect(s.interval(from: start, to: end) == nil)
        }
    }
    @Test func invalidClocksQuarantineEvenAfterRecovery() throws {
        for bad in [9.0, .nan, .infinity, 1e13] {
            var a = try make(); a.updateOccupancy(items: 1, bytes: 10, phase: .admitting, at: 10)
            a.poll(at: 12); a.poll(at: bad); a.poll(at: 20)
            #expect(a.snapshot.pressure.isQuarantined)
            #expect(a.snapshot.pressure.interval(from: 10, to: 11) == nil)
            #expect(a.snapshot.pressure.interval(from: 15, to: 20) == nil)
        }
    }
    @Test func invalidDepthQuarantinesAndPTSInvalidityDoesNot() throws {
        for depth in [(5, 10), (1, 101), (0, 1), (2, 1), (-1, 0)] {
            var a = try make(); a.updateOccupancy(items: 1, bytes: 10, phase: .admitting, at: 10)
            a.updateOccupancy(items: depth.0, bytes: depth.1, at: 12)
            a.updateOccupancy(items: 0, bytes: 0, at: 13); a.poll(at: 15)
            #expect(a.snapshot.pressure.isQuarantined)
        }
        var a = try make(); a.updateOccupancy(items: 2, bytes: 30, phase: .admitting, at: 10)
        a.observe(.admitted, sample: .init(kind: .video, sourcePTS: .invalid), at: 12)
        near(try #require(a.poll(at: 15).pressure.interval(from: 10, to: 15)).meanMaxPressure, 0.5)
    }
    @Test func closeFreezesHistoricalCoverageAndOldSnapshotIsImmutable() throws {
        var a = try make(); a.updateOccupancy(items: 1, bytes: 10, phase: .admitting, at: 10)
        let before = a.poll(at: 12).pressure
        a.updateOccupancy(items: 4, bytes: 100, at: 12)
        let closed = a.close(at: 15).pressure
        a.poll(at: 99); a.updateOccupancy(items: 0, bytes: 0, at: 100)
        #expect(closed.isClosed); #expect(a.snapshot.pressure.coveredThrough == 15)
        #expect(closed.interval(from: 10, to: 16) == nil)
        near(try #require(before.interval(from: 10, to: 12)).meanMaxPressure, 0.25)
        near(try #require(closed.interval(from: 12, to: 15)).meanMaxPressure, 1)
        #expect(before.states.count == 1)
    }
    @Test func ringEvictsOldStatesWithoutInventingEarlierCoverage() throws {
        var h = LiveIngressPressureHistory(start: 0, capacity: 3)
        for i in 0...6 { h.record(itemFraction: Double(i % 2), byteFraction: Double(i % 2), phase: .admitting, at: Double(i)) }
        h.advance(to: 7)
        let s = h.snapshot
        #expect(s.states.count == 3); #expect(s.omittedStates == 4); #expect(s.states.first?.at == 4)
        #expect(s.interval(from: 3.99, to: 7) == nil)
        near(try #require(s.interval(from: 4.5, to: 6.5)).meanMaxPressure, 0.5)
    }
    @Test func productionRingStaysBoundedAcrossTwentyThousandChanges() throws {
        var a = try make()
        for i in 0..<20_000 { a.updateOccupancy(items: i % 2, bytes: i % 2, phase: .admitting, at: 10 + Double(i) / 1000) }
        let s = a.poll(at: 30).pressure
        #expect(s.states.count == 4096); #expect(s.omittedStates == 15_904)
        #expect(s.interval(from: 10, to: 30) == nil)
        #expect(s.interval(from: 29, to: 30) != nil)
    }
    @Test func directHandoffAddsNoQueuePressure() async throws {
        let box = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 100, overflowPolicy: .dropOldest,
            ingressObservation: .init(scope: scope, monotonicAnchor: 0, initialPhase: .admitting))
        box.setObservationTimeForTesting(0)
        let consumer = Task { try await box.next() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !box.statistics.hasPendingConsumer, ContinuousClock.now < deadline { await Task.yield() }
        defer { box.cancel() }
        try #require(box.statistics.hasPendingConsumer)
        box.setObservationTimeForTesting(1); box.offer(7, bytes: 100)
        #expect(try await consumer.value == 7)
        box.setObservationTimeForTesting(5)
        let pressure = try #require(box.snapshot.ingressObservation).pressure
        near(try #require(pressure.interval(from: 0, to: 5)).meanMaxPressure, 0)
        #expect(pressure.states.count == 1)
    }
    @Test func actualMailboxDepthTransitionsSupportOffGridQueries() async throws {
        let box = try BoundedMailbox<Int>(maxItems: 2, maxBytes: 100, overflowPolicy: .dropOldest,
            ingressObservation: .init(scope: scope, monotonicAnchor: 0, initialPhase: .admitting))
        box.setObservationTimeForTesting(0); box.offer(1, bytes: 25)
        box.setObservationTimeForTesting(2); box.offer(2, bytes: 75)
        box.setObservationTimeForTesting(3); #expect(try await box.next() == 1)
        box.setObservationTimeForTesting(5)
        let s = try #require(box.snapshot.ingressObservation).pressure
        let value = try #require(s.interval(from: 0.5, to: 4.5))
        near(value.itemSeconds, 0.75 + 1 + 0.75)
        near(value.byteSeconds, 0.375 + 1 + 1.125)
        near(value.maxPressureSeconds, 0.75 + 1 + 1.125)
        box.cancel()
    }
}
