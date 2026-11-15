import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

final class VideoObservationFixtureTests: XCTestCase {
    func testReducedFileProfilesRequireExclusiveStandaloneSource() throws {
        for raw in ["240p30", "360p30", "540p30"] {
            let environment = ["SCOREBUG_TEST_FILE_CAPTURE": "1", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
                "SCOREBUG_TEST_LIVE_PROFILE": raw, "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
            XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: environment).rawValue, raw)
            for (key, value) in [("SCOREBUG_TEST_FILE_CAPTURE", "true"), ("SCOREBUG_TEST_FILE_CAPTURE", "0"),
                ("SCOREBUG_TEST_MOTION_FIXTURE", "blocks16"), ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"),
                ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", "0"), ("SCOREBUG_TEST_CANDIDATE_PROFILE", "360p30"),
                ("SCOREBUG_TEST_BANDWIDTH_PROBE", "staged"), ("SCOREBUG_TEST_MEASURED_TRIAL", "1"),
                ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "12345"), ("SCOREBUG_TEST_DECODER_STALL", "1"),
                ("SCOREBUG_TEST_NATIVE_CONFIRMATION", "1")] {
                var invalid = environment; invalid[key] = value
                XCTAssertThrowsError(try VideoObservationFixture.liveProfile(environment: invalid), "\(key)")
            }
        }
    }

    func testPublishingProxyChangesOnlyPortAndPreservesEncodedQueryBytes() throws {
        let original = try XCTUnwrap(URL(string: "srt://127.0.0.1:8890?streamid=publish%3Amatch%2Fa&passphrase=a%2Bb%26c%3Dd&latency=120&mode=caller"))
        let environment = ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_NATIVE_QUALITY": "1",
                           "SCOREBUG_TEST_UPLINK_PROXY_PORT": "54321"]
        let routed = try VideoObservationFixture.publishingURL(original, environment: environment)
        XCTAssertEqual(routed.absoluteString, original.absoluteString.replacingOccurrences(of: ":8890?", with: ":54321?"))
        XCTAssertEqual(URLComponents(url: routed, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertEqual(try VideoObservationFixture.publishingURL(original, environment: [:]), original)
        XCTAssertEqual(try VideoObservationFixture.publishingURL(original, environment: ["SCOREBUG_TEST_UPLINK_PROXY_PORT": ""]), original)
    }

    func testPublishingProxyRejectsInvalidPortOptInsAndNonFixtureURLs() throws {
        let original = try XCTUnwrap(URL(string: "srt://127.0.0.1:8890?streamid=publish%3Afixture"))
        let environment = ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_NATIVE_QUALITY": "1",
                           "SCOREBUG_TEST_UPLINK_PROXY_PORT": "54321"]
        for raw in ["0", "65536", "-1", "+1", " 1234", "1234 ", "01", "1.0", "hello"] {
            var invalid = environment; invalid["SCOREBUG_TEST_UPLINK_PROXY_PORT"] = raw
            XCTAssertThrowsError(try VideoObservationFixture.publishingURL(original, environment: invalid))
        }
        for flag in ["SCOREBUG_TEST_VIDEO_OBSERVATIONS", "SCOREBUG_TEST_NATIVE_QUALITY"] {
            for value in [nil, "0", "true"] as [String?] {
                var invalid = environment; invalid[flag] = value
                XCTAssertThrowsError(try VideoObservationFixture.publishingURL(original, environment: invalid))
            }
        }
        for raw in ["srt://example.com:8890", "srt://localhost:8890", "http://127.0.0.1:8890",
                    "srt://user:password@127.0.0.1:8890", "srt://127.0.0.1:8890#fragment",
                    "srt://127.0.0.1"] {
            XCTAssertThrowsError(try VideoObservationFixture.publishingURL(try XCTUnwrap(URL(string: raw)), environment: environment))
        }
    }

    func testOwnedRetryPublishingURLAcceptsExactLatencyAndPreservesQueryBytes() throws {
        var environment = nativeCapacityTestEnvironment()
        environment["SCOREBUG_TEST_UPLINK_PROFILE"] = "capacity750k-retry"
        environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = "270"
        environment["SCOREBUG_TEST_OWNED_MEASUREMENT"] = "1"
        for latency in ["400", "700", "1000"] {
            let original = try XCTUnwrap(URL(string: "srt://127.0.0.1:9999?streamid=publish%3Alive%2Fowned&passphrase=a%2Bb%26c%3Dd&peerlatency=\(latency)&mode=caller"))
            let routed = try VideoObservationFixture.publishingURL(original, environment: environment)
            XCTAssertEqual(routed.absoluteString, original.absoluteString.replacingOccurrences(of: ":9999?", with: ":12345?"))
            XCTAssertEqual(URLComponents(url: routed, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                           URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            XCTAssertEqual(try VideoObservationFixture.publishingURL(original, environment: [:]), original)
        }
        XCTAssertEqual(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: environment), 1.5)
    }

    func testOwnedRetryPublishingURLRejectsIncompleteRouteAndMalformedQuery() throws {
        var environment = nativeCapacityTestEnvironment()
        environment["SCOREBUG_TEST_UPLINK_PROFILE"] = "capacity750k-retry"
        environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = "270"
        environment["SCOREBUG_TEST_OWNED_MEASUREMENT"] = "1"
        for latency in ["700", "1000"] {
            let original = try XCTUnwrap(URL(string: "srt://127.0.0.1:9999?peerlatency=\(latency)"))
            for key in environment.keys {
                var missing = environment; missing.removeValue(forKey: key)
                XCTAssertThrowsError(try VideoObservationFixture.publishingURL(original, environment: missing), key)
            }
            for query in ["", "peerlatency", "peerlatency=", "peerlatency=0\(latency)", "peerlatency=\(latency).0",
                          "peerlatency=+\(latency)", "peerlatency=%20\(latency)", "peerlatency=\(latency)%20", "peerlatency=699", "peerlatency=701", "peerlatency=999",
                          "peerlatency=1001", "peerlatency=\(latency)&peerlatency=\(latency)", "peerlatency=400&peerlatency=\(latency)"] {
                XCTAssertThrowsError(try VideoObservationFixture.publishingURL(
                    XCTUnwrap(URL(string: "srt://127.0.0.1:9999?\(query)")), environment: environment), query)
            }
            for (profile, hold) in [("capacity550k", "180"), ("capacity750k", "210"), ("loss0p2-delay30", "90")] {
                var other = nativeCapacityTestEnvironment()
                other["SCOREBUG_TEST_UPLINK_PROFILE"] = profile
                other["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = hold
                if profile == "loss0p2-delay30" { other.removeValue(forKey: "SCOREBUG_TEST_CAPACITY_RECOVERY") }
                XCTAssertThrowsError(try VideoObservationFixture.publishingURL(original, environment: other), profile)
            }
        }
    }

    func testExportPreservesExactRationalTimeAndScopeWithoutSetupData() throws {
        let attempt = UUID()
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 4, publishingAttemptID: attempt, appliedProfileRevision: .max)
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        let pts = CMTime(value: 9_007_199_254_740_993, timescale: 60,
            flags: .valid, epoch: 9_007_199_254_740_995)
        accumulator.observe(.captureVideo, sourcePTS: pts, at: 0)
        let data = try VideoObservationFixture.data(for: accumulator.close(at: 2), captureDetachedAt: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertEqual(json["isClosed"] as? Bool, true)
        XCTAssertEqual(json["captureDetachedAt"] as? Double, 1)
        XCTAssertTrue(json["omittedThroughMonotonicTime"] is NSNull)
        let identity = try XCTUnwrap(json["scope"] as? [String: Any])
        XCTAssertEqual(identity["appliedProfileRevision"] as? String, "18446744073709551615")
        XCTAssertEqual(identity["publishingAttemptID"] as? String, attempt.uuidString)
        XCTAssertEqual(Set(identity.keys), ["recordingID", "matchID", "broadcastGeneration", "publishingAttemptID", "appliedProfileRevision"])
        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual(current["monotonicStart"] as? Double, 0)
        XCTAssertEqual(current["monotonicEnd"] as? Double, 2)
        let capture = try XCTUnwrap(current["captureVideo"] as? [String: Any])
        XCTAssertEqual(capture["callbackCount"] as? String, "1")
        let time = try XCTUnwrap(capture["firstSourcePTS"] as? [String: Any])
        XCTAssertEqual(time["value"] as? String, "9007199254740993")
        XCTAssertEqual(time["epoch"] as? String, "9007199254740995")
        XCTAssertEqual(time["timescale"] as? Int, 60)
        let encoded = try XCTUnwrap(current["encodedVideo"] as? [String: Any])
        XCTAssertTrue(encoded["firstSourcePTS"] is NSNull)
        XCTAssertEqual(encoded["callbackCount"] as? String, "0")
        XCTAssertEqual(Set(json.keys), ["formatVersion", "scope", "captureDetachedAt", "monotonicAnchor", "windowDuration", "current", "completed", "omittedCompletedWindowCount", "omittedThroughMonotonicTime", "rejectedClockOperationCount", "invalidity", "isClosed"])
    }

    func testIngressExportPreservesPressureDispositionsAndExactSourceTime() throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 2, publishingAttemptID: UUID(), appliedProfileRevision: .max)
        var video = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 0,
            maxItems: 2, maxBytes: 100)
        let pts = CMTime(value: 9_007_199_254_740_993, timescale: 60, flags: .valid, epoch: 9_007_199_254_740_995)
        let metadata = LiveIngressSampleMetadata(kind: .video, sourcePTS: pts)
        ingress.observe(.admitted, sample: metadata, at: 0)
        ingress.updateOccupancy(items: 1, bytes: 50, phase: .admitting, at: 0)
        ingress.observe(.overflowEvicted, sample: metadata, at: 2)
        ingress.updateOccupancy(items: 0, bytes: 0, at: 2)
        let data = try VideoObservationFixture.data(for: video.close(at: 4), captureDetachedAt: 3,
            ingressObservation: ingress.close(at: 3))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exported = try XCTUnwrap(json["ingressObservation"] as? [String: Any])
        XCTAssertEqual(exported["formatVersion"] as? Int, 1)
        XCTAssertEqual(exported["scope"] as? NSDictionary, json["scope"] as? NSDictionary)
        XCTAssertEqual(exported["phase"] as? String, "closed")
        XCTAssertEqual(exported["currentItems"] as? Int, 0)
        XCTAssertEqual(exported["currentBytes"] as? Int, 0)
        XCTAssertEqual(exported["omittedCompletedWindowCount"] as? String, "0")
        XCTAssertEqual(exported["unassignedDispositionCount"] as? String, "0")
        let pressure = try XCTUnwrap(exported["totalOccupancy"] as? [String: Any])
        XCTAssertEqual(pressure["knownDuration"] as? Double, 3)
        XCTAssertEqual(pressure["unknownDuration"] as? Double, 0)
        XCTAssertEqual(pressure["maxPressureSeconds"] as? Double, 1)
        XCTAssertEqual(pressure["peakItems"] as? Int, 1)
        XCTAssertEqual(pressure["peakBytes"] as? Int, 50)
        let dispositions = try XCTUnwrap(exported["totalDispositions"] as? [String: [String: [String: Any]]])
        XCTAssertEqual(dispositions["admitted"]?["video"]?["count"] as? String, "1")
        XCTAssertEqual(dispositions["overflowEvicted"]?["video"]?["invalidPTSCount"] as? String, "0")
        let source = try XCTUnwrap(dispositions["admitted"]?["video"]?["minimumSourcePTS"] as? [String: Any])
        XCTAssertEqual(source["value"] as? String, "9007199254740993")
        XCTAssertEqual(source["epoch"] as? String, "9007199254740995")
        XCTAssertEqual(source["timescale"] as? Int, 60)
        let current = try XCTUnwrap(exported["current"] as? [String: Any])
        XCTAssertEqual(current["coveredWindowCount"] as? String, "1")
        XCTAssertEqual(current["isClosed"] as? Bool, true)
        XCTAssertEqual(current["isCoalesced"] as? Bool, false)
        let phases = try XCTUnwrap(current["occupancyByPhase"] as? [String: [String: Any]])
        XCTAssertEqual(phases["admitting"]?["knownDuration"] as? Double, 3)
        XCTAssertLessThan(data.count, 4 * 1024 * 1024)
    }

    func testIngressExportRetainsInvalidClockAndRejectionEvidence() throws {
        let scope = VideoFrameObservationScope(recordingID: "r", matchID: "m", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        var video = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 0, maxItems: 1, maxBytes: 100)
        ingress.observe(.rejected(.oversize), sample: .init(kind: .audio, sourcePTS: .invalid), at: .nan)
        let data = try VideoObservationFixture.data(for: video.close(at: 3), captureDetachedAt: 1,
            ingressObservation: ingress.close(at: 2))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exported = try XCTUnwrap(json["ingressObservation"] as? [String: Any])
        XCTAssertNotEqual(exported["invalidity"] as? Int, 0)
        XCTAssertEqual(exported["rejectedClockOperationCount"] as? String, "1")
        XCTAssertEqual(exported["unassignedDispositionCount"] as? String, "1")
        let pressure = try XCTUnwrap(exported["totalOccupancy"] as? [String: Any])
        XCTAssertEqual(pressure["unknownDuration"] as? Double, 2)
        let dispositions = try XCTUnwrap(exported["totalDispositions"] as? [String: [String: [String: Any]]])
        let rejected = try XCTUnwrap(dispositions["rejected.oversize"]?["audio"])
        XCTAssertEqual(rejected["invalidPTSCount"] as? String, "1")
        XCTAssertTrue(rejected["minimumSourcePTS"] is NSNull)
    }

    func testPublishingClockExportPreservesFullWidthScalarsAndExactScope() throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match",
            broadcastGeneration: 4, publishingAttemptID: UUID(), appliedProfileRevision: .max)
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        let descriptor = try XCTUnwrap(PublishingTransportClock(
            sourceOrigin: CMTime(value: .min, timescale: .max, flags: [.valid, .hasBeenRounded], epoch: 0),
            publishingGeneration: .max))
        let clock = PublishingClockObservation(scope: scope, transportClock: descriptor, isClosed: true)
        let data = try VideoObservationFixture.data(for: accumulator.close(at: 2), captureDetachedAt: 1,
            publishingClockObservation: clock)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exported = try XCTUnwrap(json["publishingClockObservation"] as? [String: Any])
        XCTAssertEqual(Set(exported.keys), ["scope", "isClosed", "sourceOrigin", "publishingGeneration", "timescale", "presentationLead", "wireModulus"])
        XCTAssertEqual(exported["scope"] as? NSDictionary, json["scope"] as? NSDictionary)
        XCTAssertEqual(exported["isClosed"] as? Bool, true)
        XCTAssertEqual(exported["publishingGeneration"] as? String, "18446744073709551615")
        XCTAssertEqual(exported["timescale"] as? Int, 90000)
        XCTAssertEqual(exported["presentationLead"] as? String, "9000")
        XCTAssertEqual(exported["wireModulus"] as? String, "8589934592")
        let origin = try XCTUnwrap(exported["sourceOrigin"] as? [String: Any])
        XCTAssertEqual(Set(origin.keys), ["value", "timescale", "epoch", "flags"])
        XCTAssertEqual(origin["value"] as? String, "-9223372036854775808")
        XCTAssertEqual(origin["timescale"] as? Int, 2147483647)
        XCTAssertEqual(origin["epoch"] as? String, "0")
        XCTAssertEqual(origin["flags"] as? UInt32, descriptor.sourceOrigin.flags.rawValue)
        XCTAssertLessThan(data.count, 16 * 1024)
    }

    func testPublishingClockExportRejectsEveryScopeMismatchAndInconsistentClosure() throws {
        let scope = proofScope()
        let descriptor = try XCTUnwrap(PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 1))
        let variants = [proofScope(recording: "other"), proofScope(game: "other"), proofScope(generation: 4),
            proofScope(attempt: UUID()), VideoFrameObservationScope(recordingID: scope.recordingID,
                matchID: scope.matchID, broadcastGeneration: scope.broadcastGeneration,
                publishingAttemptID: scope.publishingAttemptID, appliedProfileRevision: 2)]
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0)
        let live = accumulator.snapshot
        let closed = accumulator.close(at: 2)
        for other in variants {
            XCTAssertThrowsError(try VideoObservationFixture.data(for: closed, captureDetachedAt: 1,
                publishingClockObservation: .init(scope: other, transportClock: descriptor, isClosed: true)))
        }
        XCTAssertThrowsError(try VideoObservationFixture.data(for: closed, captureDetachedAt: 1,
            publishingClockObservation: .init(scope: scope, transportClock: descriptor, isClosed: false)))
        XCTAssertThrowsError(try VideoObservationFixture.data(for: live, captureDetachedAt: 1,
            publishingClockObservation: .init(scope: scope, transportClock: descriptor, isClosed: true)))
    }

    func testFixtureRequiresExactExplicitFlag() {
        XCTAssertFalse(VideoObservationFixture.requested(environment: [:]))
        XCTAssertFalse(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "true"]))
        XCTAssertFalse(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "0"]))
        XCTAssertTrue(VideoObservationFixture.requested(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1"]))
    }

    func testExtendedHistoryRequiresExplicitFixtureAndCanonicalBoundedHold() {
        XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: [:]), 8)
        XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180"]), 8)
        for raw in ["", " 180", "0180", "+180", "180.0", "11", "601", "NaN"] {
            XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": raw]), 8)
        }
        for raw in ["12", "90", "180"] {
            XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": raw]), 64)
        }
        for raw in ["181", "600"] {
            XCTAssertEqual(VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": raw]), 128)
        }
    }

    func testExtendedFixtureRetainsTenMinutesWithoutEviction() throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let limit = VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "600"])
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0, completedWindowLimit: limit)
        for frame in 0..<18000 {
            let pts = CMTime(value: Int64(frame), timescale: 30)
            accumulator.observe(.captureVideo, sourcePTS: pts, at: Double(frame) / 30)
            accumulator.observe(.encodedVideo, sourcePTS: pts, at: Double(frame) / 30)
        }
        let snapshot = accumulator.close(at: 600)
        XCTAssertEqual(snapshot.completed.count, 120)
        XCTAssertEqual(snapshot.omittedCompletedWindowCount, 0)
        XCTAssertNil(snapshot.omittedThroughMonotonicTime)
    }

    func testExtendedFixtureRetainsThreeMinutesWithoutEviction() throws {
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let limit = VideoObservationFixture.completedWindowLimit(environment: ["SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1", "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "180"])
        var accumulator = try VideoFrameObservationAccumulator(scope: scope, monotonicAnchor: 0, completedWindowLimit: limit)
        for frame in 0..<5400 {
            let pts = CMTime(value: Int64(frame), timescale: 30)
            accumulator.observe(.captureVideo, sourcePTS: pts, at: Double(frame) / 30)
            accumulator.observe(.encodedVideo, sourcePTS: pts, at: Double(frame) / 30)
        }
        let snapshot = accumulator.close(at: 180)
        XCTAssertEqual(snapshot.completed.count, 36)
        XCTAssertEqual(snapshot.omittedCompletedWindowCount, 0)
        XCTAssertNil(snapshot.omittedThroughMonotonicTime)
    }
}

private let proofAttempt = UUID(uuidString: "12345678-1234-4234-9234-123456789ABC")!
private func proofScope(recording: String = "recording", attempt: UUID = proofAttempt, game: String = "game", generation: Int = 3) -> VideoFrameObservationScope {
    .init(recordingID: recording, matchID: game, broadcastGeneration: generation,
          publishingAttemptID: attempt, appliedProfileRevision: 1)
}


final class WorkerReportAgeProofTests: XCTestCase {
    private func proof(sequence: Int64 = 1, scope: VideoFrameObservationScope = proofScope(),
                       worker: String = "worker", attempt: Int = 2, residence: Duration = .nanoseconds(789)) throws -> WorkerReportAgeProof {
        let received = ContinuousClock.now
        let request = Duration.milliseconds(123)
        let window = DecodedVideoWindow(sequence: sequence, durationMs: 5000, ageMs: 250,
            firstPTS: 0, lastPTS: 447000, freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
        let response = WorkerMediaStatusResponse(status: .init(gameId: scope.matchID, generation: scope.broadcastGeneration, workerId: worker,
            state: .producingOutput, observation: .init(gameId: scope.matchID, generation: scope.broadcastGeneration, state: .producingOutput,
            reason: nil, attempt: attempt, frame: nil, outTimeUs: nil, scoreRevision: nil,
            decodedVideo: .init(completed: window, invalidReason: nil, ended: false)), observedAt: nil,
            expiresAt: "2040-01-01T00:00:05Z", decodedVideoAgeUpperBoundMs: 550), serverTime: "2040-01-01T00:00:00Z")
        let helper = try XCTUnwrap(WorkerDecodedVideoFreshness(response: response, receivedAt: received, requestDuration: request))
        let actual = helper.ageUpperBound(at: received.advanced(by: residence))
        return try XCTUnwrap(WorkerReportAgeProof(scope: scope, helper: helper, serverUpperBoundMs: 550,
            requestDuration: request, residenceDuration: residence, helperAgeUpperBound: actual))
    }

    func testHistoryReplacesSameSequenceAdvancesAtTwoAndResetsOnRewind() throws {
        var history = WorkerReportAgeProofHistory()
        history.record(try proof())
        history.record(try proof(residence: .microseconds(2)))
        XCTAssertEqual(history.proofs.count, 1)
        XCTAssertEqual(history.proofs.first?.residenceDuration.attoseconds, "2000000000000")
        history.record(try proof(sequence: 2)); history.record(try proof(sequence: 3))
        XCTAssertEqual(history.proofs.map { $0.completed.sequence }, [2, 3])
        history.record(try proof(sequence: 1))
        XCTAssertEqual(history.proofs.map { $0.completed.sequence }, [1])
    }

    func testHistoryResetsForLocalOrRemoteScopeAndNilOrLifecycleClear() throws {
        for replacement in [try proof(scope: proofScope(recording: "other")),
                            try proof(scope: proofScope(attempt: UUID())),
                            try proof(worker: "other"), try proof(attempt: 3),
                            try proof(scope: proofScope(game: "other")),
                            try proof(scope: proofScope(generation: 4))] {
            var history = WorkerReportAgeProofHistory()
            history.record(try proof()); history.record(try proof(sequence: 2)); history.record(replacement)
            XCTAssertEqual(history.proofs, [replacement])
            history.record(nil)
            XCTAssertTrue(history.proofs.isEmpty)
            history.record(replacement); history.clear()
            XCTAssertTrue(history.proofs.isEmpty)
        }
    }

    func testExportPreservesActualExactDurationReturnAndImmutableWindow() throws {
        let evidence = try proof(residence: Duration(secondsComponent: 0, attosecondsComponent: 789123456789))
        var accumulator = try VideoFrameObservationAccumulator(scope: proofScope(), monotonicAnchor: 0)
        let data = try VideoObservationFixture.data(for: accumulator.close(at: 1), captureDetachedAt: 1,
            workerReportAgeProofs: [evidence])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proofs = try XCTUnwrap(json["workerReportAgeProofs"] as? [[String: Any]])
        XCTAssertEqual(proofs.count, 1)
        let p = proofs[0]
        XCTAssertEqual(p["evaluatedAt"] as? String, "pollControl")
        XCTAssertEqual(p["decodedVideoAgeUpperBoundMs"] as? Int64, 550)
        XCTAssertEqual(p["requestDuration"] as? [String: String], ["seconds": "0", "attoseconds": "123000000000000000"])
        XCTAssertEqual(p["residenceDuration"] as? [String: String], ["seconds": "0", "attoseconds": "789123456789"])
        XCTAssertEqual(p["helperAgeUpperBound"] as? [String: String], ["seconds": "0", "attoseconds": "673000789123456789"])
        XCTAssertTrue(p["invalidReason"] is NSNull)
        XCTAssertEqual((p["completed"] as? [String: Any])?["freshFrames"] as? Int, 150)
    }
}
