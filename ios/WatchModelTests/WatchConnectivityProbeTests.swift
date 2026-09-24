import XCTest

final class WatchConnectivityProbeTests: XCTestCase {
    func testRequiresOptInAndEligibilityAndOnlyStartsOnce() {
        let off = WatchConnectivityProbeGate(enabled: false)
        XCTAssertFalse(off.begin(eligible: true, now: 10))
        let gate = WatchConnectivityProbeGate(enabled: true)
        XCTAssertFalse(gate.begin(eligible: false, now: 10))
        XCTAssertTrue(gate.begin(eligible: true, now: 10))
        XCTAssertFalse(gate.begin(eligible: true, now: 10.1))
        XCTAssertEqual(gate.finish(.reply, now: 10.2), .reply)
        XCTAssertFalse(gate.begin(eligible: true, now: 20))
    }
    func testFixedProbeCannotBecomeAProductionRelayRequest() {
        XCTAssertEqual(WatchConnectivityProbeGate.payload, Data([0]))
        XCTAssertThrowsError(try WatchRelayInboundRequest(validating: WatchConnectivityProbeGate.payload))
    }
    func testDeadlineAndInvalidClockFailClosed() {
        for end in [12.0, 13, Double.nan, Double.infinity, 9] {
            let gate = WatchConnectivityProbeGate(enabled: true)
            XCTAssertTrue(gate.begin(eligible: true, now: 10))
            XCTAssertEqual(gate.finish(.reply, now: end), .timedOut)
            XCTAssertNil(gate.finish(.failed, now: 11))
        }
        for start in [Double.nan, Double.infinity, -1, Double.greatestFiniteMagnitude] {
            XCTAssertFalse(WatchConnectivityProbeGate(enabled: true).begin(eligible: true, now: start))
        }
    }
    func testTimeoutAndDuplicateCallbacksHaveOneOutcome() {
        let gate = WatchConnectivityProbeGate(enabled: true)
        XCTAssertNil(gate.finish(.reply, now: 1))
        XCTAssertTrue(gate.begin(eligible: true, now: 10))
        XCTAssertEqual(gate.finish(.timedOut, now: 12), .timedOut)
        XCTAssertNil(gate.finish(.reply, now: 12.1))
    }
    func testNativeFailureAndUnexpectedReplyStayDistinct() {
        for result in [WatchConnectivityProbeGate.Outcome.failed, .unexpectedReply] {
            let gate = WatchConnectivityProbeGate(enabled: true)
            XCTAssertTrue(gate.begin(eligible: true, now: 10))
            XCTAssertEqual(gate.finish(result, now: 10.1), result)
        }
    }
    func testConcurrentTerminalClaimsResolveOnce() {
        let gate = WatchConnectivityProbeGate(enabled: true)
        XCTAssertTrue(gate.begin(eligible: true, now: 10))
        let lock = NSLock(); var count = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if gate.finish(.reply, now: 11) != nil { lock.lock(); count += 1; lock.unlock() }
        }
        XCTAssertEqual(count, 1)
    }
}
