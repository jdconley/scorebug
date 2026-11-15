import Foundation
import ScorebugMedia
import XCTest

final class NativeCapacityClockTests: XCTestCase {
    private var scope: VideoFrameObservationScope { .init(recordingID: "recording", matchID: "match",
        broadcastGeneration: 1, publishingAttemptID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, appliedProfileRevision: 1) }
    private func request(_ sequence: Int, nonce: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "sequence": sequence,
            "nonce": nonce ?? String(format: "00000000-0000-4000-8000-%012d", sequence),
            "scope": ["recordingID": "recording", "matchID": "match", "broadcastGeneration": 1,
                "publishingAttemptID": scope.publishingAttemptID.uuidString.lowercased(), "appliedProfileRevision": "1"]])
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testFourOrderedChallengesRetainExactSamplesAndNeverFreshenDuplicates() throws {
        var audit = try NativeCapacityClockAudit(scope: scope)
        var samples: [[String: Any]] = []
        for sequence in 1...4 {
            let bytes = try request(sequence), at = Double(sequence) + 900000
            let response = try object(XCTUnwrap(audit.respond(to: bytes, at: at)))
            samples.append(try XCTUnwrap(response["sample"] as? [String: Any]))
            XCTAssertNil(try audit.respond(to: bytes, at: at + 0.1))
        }
        audit.close()
        let result = try object(audit.data())
        XCTAssertEqual(result["maximumSamples"] as? Int, 4)
        XCTAssertEqual(result["closed"] as? Bool, true)
        XCTAssertEqual(result["invalid"] as? Bool, false)
        XCTAssertEqual(result["overflow"] as? Bool, false)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: result["samples"]!, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]))
        let closed = try audit.data()
        XCTAssertNil(try audit.respond(to: request(5), at: 900005))
        XCTAssertEqual(try audit.data(), closed)
    }
    func testRejectsMalformedForeignOutOfOrderAndOversizedChallengesPermanently() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["formatVersion"] = 2 }, { $0["sequence"] = 2 }, { $0["sequence"] = true },
            { $0["nonce"] = "bad" }, { $0["extra"] = "field" }, { $0.removeValue(forKey: "nonce") },
            { var scope = $0["scope"] as! [String: Any]; scope["recordingID"] = "other"; $0["scope"] = scope },
            { var scope = $0["scope"] as! [String: Any]; scope["extra"] = "field"; $0["scope"] = scope }
        ]
        for mutate in mutations {
            var audit = try NativeCapacityClockAudit(scope: scope), raw = try object(request(1))
            mutate(&raw)
            XCTAssertThrowsError(try audit.respond(to: JSONSerialization.data(withJSONObject: raw), at: 1))
            XCTAssertEqual(try object(audit.data())["invalid"] as? Bool, true)
            XCTAssertNil(try audit.respond(to: request(1), at: 2))
            XCTAssertEqual((try object(audit.data())["samples"] as? [Any])?.count, 0)
        }
        for bytes in [Data(repeating: 120, count: 4097), Data("{".utf8)] {
            var audit = try NativeCapacityClockAudit(scope: scope)
            XCTAssertThrowsError(try audit.respond(to: bytes, at: 1))
            XCTAssertEqual(try object(audit.data())["invalid"] as? Bool, true)
        }
    }
    func testNonceAndClockCannotRegressAndFifthChallengeOverflows() throws {
        for (sequence, nonce, at) in [(2, "00000000-0000-4000-8000-000000000001", 2.0),
                                      (2, "00000000-0000-4000-8000-000000000002", 1.0)] {
            var audit = try NativeCapacityClockAudit(scope: scope)
            _ = try audit.respond(to: request(1), at: 1)
            XCTAssertThrowsError(try audit.respond(to: request(sequence, nonce: nonce), at: at))
        }
        for at in [Double.nan, .infinity, -1, 1e12 + 1] {
            var audit = try NativeCapacityClockAudit(scope: scope)
            XCTAssertThrowsError(try audit.respond(to: request(1), at: at))
        }
        var audit = try NativeCapacityClockAudit(scope: scope)
        for sequence in 1...4 { _ = try audit.respond(to: request(sequence), at: Double(sequence)) }
        XCTAssertThrowsError(try audit.respond(to: request(5), at: 5))
        XCTAssertEqual(try object(audit.data())["overflow"] as? Bool, true)
        XCTAssertEqual((try object(audit.data())["samples"] as? [Any])?.count, 4)
    }
    func testActorReadsBoundedAtomicChallengeAndJoinsClosedAudit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try NativeCapacityClockFixture(scope: scope, directory: directory)
        await fixture.poll() // No request is normal before the host starts.
        for sequence in 1...4 {
            try request(sequence).write(to: directory.appendingPathComponent("capacity-clock-request.json"), options: .atomic)
            await fixture.poll()
            let reply = try object(Data(contentsOf: directory.appendingPathComponent("capacity-clock-response.json")))
            XCTAssertEqual((reply["sample"] as? [String: Any])?["sequence"] as? Int, sequence)
        }
        await fixture.closeAndExport()
        let bytes = try Data(contentsOf: directory.appendingPathComponent("capacity-clock.json")), audit = try object(bytes)
        XCTAssertEqual(audit["closed"] as? Bool, true)
        XCTAssertEqual(audit["invalid"] as? Bool, false)
        XCTAssertEqual((audit["samples"] as? [Any])?.count, 4)
        XCTAssertLessThanOrEqual(bytes.count, 16384)
        await fixture.poll()
        await fixture.closeAndExport()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("capacity-clock.json")), bytes)
    }
    func testActorRejectsSymlinkDirectoryOversizedAndMalformedRequestsWithoutReply() async throws {
        for kind in ["symlink", "directory", "oversized", "malformed"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try NativeCapacityClockFixture(scope: scope, directory: directory)
            let url = directory.appendingPathComponent("capacity-clock-request.json")
            if kind == "symlink" {
                let target = directory.appendingPathComponent("target.json")
                try request(1).write(to: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            } else if kind == "directory" {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try (kind == "oversized" ? Data(repeating: 120, count: 4097) : Data("{".utf8)).write(to: url)
            }
            await fixture.poll(); await fixture.closeAndExport()
            let audit = try object(Data(contentsOf: directory.appendingPathComponent("capacity-clock.json")))
            XCTAssertEqual(audit["invalid"] as? Bool, true, kind)
            XCTAssertEqual((audit["samples"] as? [Any])?.count, 0, kind)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capacity-clock-response.json").path), kind)
        }
    }

    func testCancelledPollingDoesNotReadPendingChallengeAndJoinsBeforeExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try NativeCapacityClockFixture(scope: scope, directory: directory)
        try request(1).write(to: directory.appendingPathComponent("capacity-clock-request.json"), options: .atomic)
        let gate = FilmTestGate()
        let polling = Task.detached {
            await gate.enter()
            await fixture.runPolling()
        }
        await gate.waitUntilEntered()
        polling.cancel()
        await gate.release()
        await polling.value
        await fixture.closeAndExport()
        let audit = try object(Data(contentsOf: directory.appendingPathComponent("capacity-clock.json")))
        XCTAssertEqual(audit["closed"] as? Bool, true)
        XCTAssertEqual(audit["invalid"] as? Bool, false)
        XCTAssertEqual((audit["samples"] as? [Any])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capacity-clock-response.json").path))
    }

    func testActivePollingCancellationJoinsAndClosedFixtureCannotSampleAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try NativeCapacityClockFixture(scope: scope, directory: directory)
        let polling = Task.detached { await fixture.runPolling() }
        try request(1).write(to: directory.appendingPathComponent("capacity-clock-request.json"), options: .atomic)
        let responseURL = directory.appendingPathComponent("capacity-clock-response.json")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: responseURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        polling.cancel()
        await polling.value
        await fixture.closeAndExport()
        let response = try Data(contentsOf: responseURL)
        let closed = try Data(contentsOf: directory.appendingPathComponent("capacity-clock.json"))
        let audit = try object(closed)
        XCTAssertEqual(audit["closed"] as? Bool, true)
        XCTAssertEqual((audit["samples"] as? [Any])?.count, 1)
        try request(2).write(to: directory.appendingPathComponent("capacity-clock-request.json"), options: .atomic)
        await fixture.runPolling()
        await fixture.poll()
        await fixture.closeAndExport()
        XCTAssertEqual(try Data(contentsOf: responseURL), response)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("capacity-clock.json")), closed)
    }

}
