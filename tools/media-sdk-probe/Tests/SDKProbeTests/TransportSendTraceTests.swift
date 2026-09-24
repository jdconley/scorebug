import XCTest
@testable import SDKProbe

final class TransportSendTraceTests: XCTestCase {
    func testSealMakesUnreturnedAttemptExplicitAndRejectsLateReturn() {
        let trace = TransportSendTrace(capacity: 4, now: { 10 })
        trace.record(row("started", 1))
        let sealed = trace.seal()
        XCTAssertEqual(sealed.scope, "boundedPrefix")
        XCTAssertEqual(sealed.cutoffAt, 10)
        XCTAssertEqual(sealed.openAttempts, ["7:1"])
        XCTAssertEqual(sealed.rows.count, 1)
        // An unhealthy stream can cancel without joining its transport consumer.
        trace.record(row("returned", 2))
        XCTAssertEqual(trace.seal(), sealed)
    }
    func testPairedReturnRemovesOnlyItsOwnGenerationAndSequence() {
        let trace = TransportSendTrace(capacity: 6, now: { 10 })
        trace.record(row("started", 1)); trace.record(row("returned", 2))
        trace.record(row("started", 3, generation: "8"))
        XCTAssertEqual(trace.seal().openAttempts, ["8:1"])
    }
    func testCapacityOverflowIsExplicitAndRetainsBoundedPrefix() {
        let trace = TransportSendTrace(capacity: 1, now: { 10 })
        trace.record(row("started", 1)); trace.record(row("returned", 2))
        let value = trace.seal()
        XCTAssertEqual(value.maximumEvents, 1)
        XCTAssertTrue(value.overflow)
        XCTAssertEqual(value.rows.count, 1)
        XCTAssertEqual(value.openAttempts, ["7:1"])
    }
    private func row(_ phase: String, _ at: Double, generation: String = "7") -> TransportSendTrace.Row {
        .init(publishingGeneration: generation, sequence: "1", phase: phase,
              byteCount: 1316, pendingPacketCount: 0, observedAt: at)
    }
}
