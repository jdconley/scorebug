import Foundation
import ScorebugCore
import XCTest

final class WatchRelaySessionGateTests: XCTestCase {
    func testInboundKindsPreserveCorrelationForImmediateAndStaleFailureReplies() throws {
        let scope = WatchRelayScope(endpoint: "https://example.com", gameId: "fixture-game",
            watchDeviceId: "00000000-0000-4000-8000-000000000014", pairingId: "00000000-0000-4000-8000-000000000015")
        let score = WatchRelayRequest(requestId: UUID().uuidString, scope: scope,
            credential: MatchCredential(gameId: scope.gameId, deviceId: scope.watchDeviceId, role: .score,
                token: String(repeating: "A", count: 43)), operation: .snapshot)
        let bootstrap = WatchBootstrapRequest(requestId: UUID().uuidString,
            authority: WatchBootstrapAuthority(scope: scope, pairingToken: String(repeating: "A", count: 43)),
            redemption: WatchPairingRedeemRequest(redemptionId: UUID().uuidString, deviceId: scope.watchDeviceId),
            recoveryKey: String(repeating: "B", count: 42) + "A")
        let scoringInput = try WatchRelayInboundRequest(validating: WatchRelayCodec.encodeRequest(score))
        let bootstrapInput = try WatchRelayInboundRequest(validating: WatchBootstrapCodec.encodeRequest(bootstrap))
        guard case .scoring(let decodedScore) = scoringInput,
              case .bootstrap(let decodedBootstrap) = bootstrapInput else { return XCTFail("Expected distinct native dispatch kinds") }
        XCTAssertEqual(decodedScore, score); XCTAssertEqual(decodedBootstrap, bootstrap)
        for failure in [WatchRelayFailure.busy, .cancelled, .scopeMismatch] {
            XCTAssertEqual(try WatchRelayCodec.decodeReply(scoringInput.failureReply(failure), for: score).result, .failure(failure))
            XCTAssertEqual(try WatchBootstrapCodec.decodeReply(bootstrapInput.failureReply(failure), for: bootstrap).result, .failure(failure))
        }
    }

    func testInboundValidationRejectsUnknownOrOversizedDataBeforeActorDispatch() {
        let invalid = [Data(), Data("not-json".utf8), Data(#"{"type":"arbitrary_http","url":"https://example.com"}"#.utf8),
            Data(repeating: 32, count: WatchRelayInboundRequest.maximumRequestBytes + 1)]
        for data in invalid {
            XCTAssertThrowsError(try WatchRelayInboundRequest(validating: data))
        }
    }

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
