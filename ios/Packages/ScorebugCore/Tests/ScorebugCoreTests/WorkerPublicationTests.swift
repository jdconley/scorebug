import Foundation
import ScorebugCore
import XCTest

final class WorkerPublicationTests: XCTestCase {
    private func fixture() throws -> [String: WorkerMediaStatusResponse] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-publication-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: WorkerMediaStatusResponse].self, from: Data(contentsOf: url))
    }

    func testValidPublicationAndLegacyFixtureRoundTrip() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "worker-publication-v1", withExtension: "json", subdirectory: "Fixtures"))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: NSDictionary])
        let responses = try fixture()
        for name in ["current", "starting", "zeroOrigin", "maximumOrigin", "legacy"] {
            let response = try XCTUnwrap(responses[name])
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                           wire[name], name)
        }
    }

    func testSharedFixtureValidatesOnlyScopedCanonicalPublications() throws {
        let valid = Set(["current", "starting", "zeroOrigin", "maximumOrigin"])
        for (name, response) in try fixture() {
            XCTAssertEqual(response.status.validatedPublication != nil, valid.contains(name), name)
            XCTAssertEqual(response.status.gameId, "match", name)
            XCTAssertEqual(response.status.generation, 2, name)
        }
    }

    func testMalformedOptionalShapesDoNotBreakOrdinaryStatus() throws {
        let responses = try fixture()
        for name in ["invalidPublicationType", "invalidPublicationArray", "invalidPublicationNull", "invalidPublicationMissing",
                     "invalidReaderType", "invalidClockType", "invalidOriginType"] {
            let status = try XCTUnwrap(responses[name]?.status)
            XCTAssertNil(status.publication, name)
            XCTAssertEqual(status.state, .producingOutput, name)
            XCTAssertEqual(status.observation?.attempt, 1, name)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
            XCTAssertNil(encoded["publication"], name)
        }
    }

    func testEveryIdentityRequiresExactlyCanonicalLowercaseUUID() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        let paths: [WritableKeyPath<WorkerPublication, String>] = [\.readerId, \.publisherId, \.publishingAttemptId]
        let id = try XCTUnwrap(original.publication?.readerId)
        for path in paths {
            for invalid in ["", "id", id.uppercased(), id + "\n", " " + id, id + "x", id.replacingOccurrences(of: "-", with: ""),
                            "g0000000-0000-0000-0000-00000000000a"] {
                var status = original
                status.publication?[keyPath: path] = invalid
                XCTAssertNil(status.validatedPublication, invalid)
            }
        }
        // These wire IDs intentionally do not impose UUID version or variant constraints.
        XCTAssertNotNil(original.validatedPublication)
        for epoch in [nil, "", id.uppercased(), id + "\n", "invalid"] as [String?] {
            var status = original
            status.workerEpoch = epoch
            XCTAssertNil(status.validatedPublication)
        }
    }

    func testOriginRequiresCanonicalUnsignedDecimalBelow33BitModulus() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        for invalid in ["", "00", "01", "-1", "+1", "1.0", "1e3", " 1", "1 ", "1\n", "１２", "8589934592", "18446744073709551616"] {
            var status = original
            status.publication?.clock.originPTS = invalid
            XCTAssertNil(status.validatedPublication, invalid)
        }
        for valid in ["0", "1", "2147483648", "8589934591"] {
            var status = original
            status.publication?.clock.originPTS = valid
            XCTAssertEqual(status.validatedPublication?.clock.originPTS, valid)
        }
    }

    func testMutableValuesAreRevalidatedAgainstObservationScope() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        for state in WorkerMediaState.allCases where state != .starting && state != .producingOutput {
            var status = original
            status.state = state
            XCTAssertNil(status.validatedPublication, state.rawValue)
        }
        var status = original
        status.observation?.attempt = -1
        XCTAssertNil(status.validatedPublication)
        status = original
        status.gameId = "other"
        XCTAssertNil(status.validatedPublication)
        status = original
        status.generation += 1
        XCTAssertNil(status.validatedPublication)
        status = original
        status.publication?.publisherId = original.publication?.readerId ?? ""
        XCTAssertNil(status.validatedPublication)
        status = original
        status.publication?.clock.convention = "mpegts-ingress-origin-90k-v1\n"
        XCTAssertNil(status.validatedPublication)
    }

    func testInitializerSupportsPublicationAndRemainsBackwardCompatible() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        var initialized = WorkerMediaStatus(gameId: original.gameId, generation: original.generation, workerId: original.workerId,
                                            state: original.state, observation: original.observation,
                                            observedAt: original.observedAt, expiresAt: original.expiresAt,
                                            workerEpoch: original.workerEpoch)
        XCTAssertNil(initialized.publication)
        initialized.publication = WorkerPublication(readerId: "10000000-0000-0000-0000-00000000000a",
                                                    publisherId: "20000000-0000-0000-0000-00000000000b",
                                                    publishingAttemptId: "30000000-0000-0000-0000-00000000000c",
                                                    clock: WorkerPublicationClock(convention: "mpegts-ingress-origin-90k-v1", originPTS: "90000"))
        XCTAssertEqual(initialized.validatedPublication, original.publication)
    }

    func testValidatedPublicationDoesNotClaimStatusFreshness() throws {
        var response = try XCTUnwrap(fixture()["current"])
        response.status.expiresAt = response.serverTime
        let receipt = ContinuousClock.now
        XCTAssertNotNil(response.status.validatedPublication)
        XCTAssertFalse(WorkerStatusFreshness(response: response, receivedAt: receipt, requestDuration: .zero).isFresh(at: receipt))
    }

    func testSelectedWorkerAndMatchingGameScopeMustBeBoundedIdentifiers() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        let invalidIdentifiers = ["", " ", "match\n", "match/other", "mátch", String(repeating: "a", count: 129)]
        func assertRejected(_ status: WorkerMediaStatus, _ label: String) throws {
            XCTAssertNil(status.validatedPublication, "mutable: \(label)")
            let decoded = try JSONDecoder().decode(WorkerMediaStatus.self, from: JSONEncoder().encode(status))
            XCTAssertNil(decoded.validatedPublication, "decoded: \(label)")
            XCTAssertEqual(decoded.state, .producingOutput)
        }
        for workerId in [nil] + invalidIdentifiers.map(Optional.some) {
            var status = original
            status.workerId = workerId
            try assertRejected(status, "worker \(String(describing: workerId))")
        }
        for gameId in invalidIdentifiers {
            var status = original
            status.gameId = gameId
            status.observation?.gameId = gameId
            try assertRejected(status, "game \(gameId)")
        }
        for identifier in ["a", "A0_-", String(repeating: "a", count: 128)] {
            var status = original
            status.workerId = identifier
            status.gameId = identifier
            status.observation?.gameId = identifier
            XCTAssertNotNil(status.validatedPublication, identifier)
        }
    }

    func testInitializerAndMutationRequirePositiveSafeScopeCounters() throws {
        let original = try XCTUnwrap(fixture()["current"]?.status)
        let aboveSafeInteger: Int64 = 9_007_199_254_740_992
        let invalidCounters = [0, -1] + [Int(exactly: aboveSafeInteger)].compactMap { $0 }
        for generation in invalidCounters {
            var observation = original.observation
            observation?.generation = generation
            var status = WorkerMediaStatus(gameId: original.gameId, generation: generation, workerId: original.workerId,
                                           state: original.state, observation: observation, observedAt: nil, expiresAt: nil,
                                           workerEpoch: original.workerEpoch, publication: original.publication)
            XCTAssertNil(status.validatedPublication, "initialized generation \(generation)")
            status = original
            status.generation = generation
            status.observation?.generation = generation
            XCTAssertNil(status.validatedPublication, "mutated generation \(generation)")
            let decoded = try JSONDecoder().decode(WorkerMediaStatus.self, from: JSONEncoder().encode(status))
            XCTAssertNil(decoded.validatedPublication, "decoded generation \(generation)")
        }
        for attempt in invalidCounters {
            var status = original
            status.observation?.attempt = attempt
            XCTAssertNil(status.validatedPublication, "attempt \(attempt)")
        }
        let maximumSafeInteger: Int64 = 9_007_199_254_740_991
        let maximumCounter = Int(exactly: maximumSafeInteger) ?? Int.max
        for counter in [1, maximumCounter] {
            var status = original
            status.generation = counter
            status.observation?.generation = counter
            status.observation?.attempt = counter
            XCTAssertNotNil(status.validatedPublication, "valid counter \(counter)")
        }
    }
}
