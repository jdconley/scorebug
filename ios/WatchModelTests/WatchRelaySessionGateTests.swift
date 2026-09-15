import Foundation
import ScorebugCore
import XCTest

final class WatchRelaySessionGateTests: XCTestCase {
    func testOnlyOneConcurrentMessageIsAdmitted() {
        let gate = WatchRelaySessionGate(), admitted = LockedValues<WatchRelaySessionGate.Token>()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let token = gate.admit() { admitted.append(token) }
        }
        XCTAssertEqual(admitted.values.count, 1)
        XCTAssertTrue(gate.isCurrent(admitted.values[0]))
        XCTAssertNil(gate.admit())
    }

    func testPeerChangeInvalidatesTokenBeforeActorDeliveryWithoutFreeingCapacity() throws {
        let gate = WatchRelaySessionGate(), epoch = gate.currentEpoch
        let token = try XCTUnwrap(gate.admit())
        let transition = gate.invalidatePeer()
        XCTAssertFalse(gate.isCurrentEpoch(epoch))
        XCTAssertFalse(gate.isCurrent(token))
        XCTAssertNil(gate.admit(), "Old HTTP work retains admission until joined")
        gate.release(token)
        XCTAssertNil(gate.admit())
        gate.completePeerChange(transition)
        let replacement = try XCTUnwrap(gate.admit())
        XCTAssertTrue(gate.isCurrent(replacement))
        XCTAssertTrue(gate.isCurrentEpoch(gate.currentEpoch))
    }

    func testIdlePeerTransitionClosesAdmissionBeforeActorReset() {
        let gate = WatchRelaySessionGate()
        gate.invalidatePeer()
        XCTAssertNil(gate.admit(), "New-epoch requests cannot use the old binding while actor cleanup is queued")
    }

    func testStalePeerResetCannotReopenNewerTransition() throws {
        let gate = WatchRelaySessionGate()
        let old = gate.invalidatePeer()
        let current = gate.invalidatePeer()
        gate.completePeerChange(old)
        XCTAssertFalse(gate.isCurrentEpoch(old))
        XCTAssertNil(gate.admit())
        gate.completePeerChange(current)
        let token = try XCTUnwrap(gate.admit())
        gate.completePeerChange(old)
        XCTAssertTrue(gate.isCurrent(token))
        XCTAssertNil(gate.admit())
    }

    func testLateDuplicateReleaseCannotFreeNewRequest() throws {
        let gate = WatchRelaySessionGate()
        let old = try XCTUnwrap(gate.admit())
        gate.release(old)
        let new = try XCTUnwrap(gate.admit())
        gate.release(old)
        XCTAssertNil(gate.admit())
        XCTAssertFalse(gate.isCurrent(old))
        XCTAssertTrue(gate.isCurrent(new))
        gate.release(new)
        XCTAssertNotNil(gate.admit())
    }

    func testReplyHandlerExecutesOnlyOnceAcrossConcurrentTerminalCallbacks() {
        let values = LockedValues<Data>()
        let reply = WatchRelayReplyOnce { values.append($0) }
        DispatchQueue.concurrentPerform(iterations: 32) { index in reply.send(Data([UInt8(index)])) }
        XCTAssertEqual(values.values.count, 1)
        XCTAssertEqual(values.values[0].count, 1)
    }

    func testReplyBoundsAndEmptyRejectionRemainTerminal() {
        for bytes in [Data(), Data(repeating: 65, count: WatchRelayCodec.maximumReplyBytes),
                      Data(repeating: 65, count: WatchRelayCodec.maximumReplyBytes + 1)] {
            let values = LockedValues<Data>()
            let reply = WatchRelayReplyOnce { values.append($0) }
            reply.send(bytes)
            reply.send(Data("late".utf8))
            XCTAssertEqual(values.values, [bytes.count <= WatchRelayCodec.maximumReplyBytes ? bytes : Data()])
        }
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
