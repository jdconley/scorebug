import XCTest

final class NativeMeasuredTrialFixtureTests: XCTestCase {
    private var valid: [String: String] { [
        "SCOREBUG_TEST_MEASURED_TRIAL": "1", "SCOREBUG_TEST_CANDIDATE_HEADROOM": "1",
        "SCOREBUG_TEST_CANDIDATE_PROFILE": "360p30", "SCOREBUG_TEST_BANDWIDTH_PROBE": "staged",
        "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
        "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": "1", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
        "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90", "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": "1500"
    ] }

    func testMeasuredFileLinkRequiresCompleteProfileAndGeneratedPort() throws {
        for profile in ["passthrough", "loss0p2-delay30"] {
            var environment = valid
            environment.removeValue(forKey: "SCOREBUG_TEST_MOTION_FIXTURE")
            environment["SCOREBUG_TEST_FILE_CAPTURE"] = "1"
            environment["SCOREBUG_TEST_UPLINK_PROFILE"] = profile
            environment["SCOREBUG_TEST_UPLINK_PROXY_PORT"] = "12345"
            XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
            XCTAssertEqual(try NativeCandidateFixture.requested(environment: environment), .low360)
            XCTAssertEqual(try VideoObservationFixture.liveProfile(environment: environment), .low240)
            let query = profile == "loss0p2-delay30" ? "streamid=publish%3Alive&peerlatency=400" : "streamid=publish%3Alive&latency=120"
            let original = URL(string: "srt://127.0.0.1:9999?\(query)")!
            XCTAssertEqual(try VideoObservationFixture.publishingURL(original, environment: environment).absoluteString,
                           "srt://127.0.0.1:12345?\(query)")
            if profile == "loss0p2-delay30" {
                for suffix in ["", "&peerlatency=120", "&peerlatency=0400", "&peerlatency=400&peerlatency=400"] {
                    let badURL = URL(string: "srt://127.0.0.1:9999?streamid=publish%3Alive\(suffix)")!
                    XCTAssertThrowsError(try VideoObservationFixture.publishingURL(badURL, environment: environment))
                }
            }
            for (key, values) in [
                "SCOREBUG_TEST_UPLINK_PROFILE": ["", "rate4m", "loss1"],
                "SCOREBUG_TEST_UPLINK_PROXY_PORT": ["", "0", "012345", "65536", "host"],
                "SCOREBUG_TEST_BANDWIDTH_PROBE": ["repeated", "renew"],
                "SCOREBUG_TEST_FILE_CAPTURE": ["", "0"],
                "SCOREBUG_TEST_MOTION_FIXTURE": ["blocks16"],
                "SCOREBUG_TEST_CANDIDATE_PROFILE": ["540p30"],
                "SCOREBUG_TEST_MEASURED_TRIAL": ["0"],
                "SCOREBUG_TEST_MEASURED_RECOVERY": ["decoder-stall"],
                "SCOREBUG_TEST_STREAM_HOLD_SECONDS": ["089", "89", "601"]
            ] {
                for value in values {
                    var bad = environment; bad[key] = value
                    XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: bad), "\(key)=\(value)")
                    XCTAssertThrowsError(try VideoObservationFixture.publishingURL(original, environment: bad), "\(key)=\(value)")
                }
            }
        }
    }

    func testFileMeasuredRouteRetainsFullAdmissionAndExactRepeatedSelection() throws {
        for probe in ["staged", "repeated"] {
            var environment = valid
            environment.removeValue(forKey: "SCOREBUG_TEST_MOTION_FIXTURE")
            environment["SCOREBUG_TEST_FILE_CAPTURE"] = "1"
            environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] = probe
            environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = probe == "repeated" ? "180" : "90"
            XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
            XCTAssertTrue(WorkerCadenceReportAudit.requested(environment: environment))
            XCTAssertEqual(try NativeCandidateFixture.requested(environment: environment), .low360)
            XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: environment)?.rawValue, probe)
            for key in environment.keys where key != "SCOREBUG_TEST_MEASURED_TRIAL" {
                var missing = environment; missing.removeValue(forKey: key)
                XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: missing), key)
            }
            for (key, value) in [("SCOREBUG_TEST_MOTION_FIXTURE", "blocks16"), ("SCOREBUG_TEST_FILE_CAPTURE", "true"),
                ("SCOREBUG_TEST_CANDIDATE_PROFILE", "540p30"), ("SCOREBUG_TEST_DELIVERY_DEADLINE_MS", "1000"),
                ("SCOREBUG_TEST_NATIVE_QUALITY", "1"), ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "1234"),
                ("SCOREBUG_TEST_CADENCE_REPORTS", "1"), ("SCOREBUG_TEST_SOURCE_CADENCE_PACING", "1")] {
                var invalid = environment; invalid[key] = value
                XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: invalid), key)
            }
            if probe == "repeated" {
                environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = "90"
                XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: environment))
            }
        }
    }

    func testExplicitMeasuredRouteAndOrdinaryRouteIsolation() throws {
        XCTAssertFalse(try NativeMeasuredTrialFixture.requested(environment: [:]))
        XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: valid))
        XCTAssertTrue(WorkerCadenceReportAudit.requested(environment: valid))
        XCTAssertFalse(WorkerCadenceReportAudit.requested(environment: [:]))
        XCTAssertEqual(try PublishingDeliveryMonitor.fixtureLatencyBudget(environment: valid), 1.5)
        XCTAssertEqual(try NativeCandidateFixture.requested(environment: valid), .low360)
        XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: valid), .staged)
        for hold in ["90", "600"] {
            var environment = valid; environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] = hold
            XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
        }
    }

    func testRepeatedRouteRequiresMeasuredTrialAndExactCandidateTarget() throws {
        var environment = valid; environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] = "repeated"
        XCTAssertTrue(try NativeMeasuredTrialFixture.requested(environment: environment))
        XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: environment), .repeated)
        XCTAssertEqual(try NativeCandidateFixture.requested(environment: environment), .low360)
        for key in ["SCOREBUG_TEST_MEASURED_TRIAL", "SCOREBUG_TEST_CANDIDATE_HEADROOM"] {
            var missing = environment; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: missing))
        }
        environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] = "540p30"
        XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: environment))
        XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: environment))
    }

    func testMeasuredRouteRejectsMissingPrerequisitesAndOtherControllers() throws {
        for key in valid.keys where key != "SCOREBUG_TEST_MEASURED_TRIAL" {
            var environment = valid; environment.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: environment), key)
        }
        for (key, values) in [
            "SCOREBUG_TEST_MEASURED_TRIAL": ["", "0", "true"],
            "SCOREBUG_TEST_CANDIDATE_HEADROOM": ["0"],
            "SCOREBUG_TEST_CANDIDATE_PROFILE": ["540p30", "1080p30"],
            "SCOREBUG_TEST_BANDWIDTH_PROBE": ["renew", "expire"],
            "SCOREBUG_TEST_LIVE_PROFILE": ["360p30"],
            "SCOREBUG_TEST_MOTION_FIXTURE": ["1"],
            "SCOREBUG_TEST_DIRECT_RTMP_RECORDER": ["0"],
            "SCOREBUG_TEST_VIDEO_OBSERVATIONS": ["0"],
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": ["89", "601", "90.5", "090"],
            "SCOREBUG_TEST_NATIVE_QUALITY": ["1"], "SCOREBUG_TEST_NATIVE_CONFIRMATION": ["1"],
            "SCOREBUG_TEST_ADAPTIVE_PROFILES": ["1"], "SCOREBUG_TEST_PROFILE_TRANSITIONS": ["1"],
            "SCOREBUG_TEST_SOURCE_CADENCE_PACING": ["1"], "SCOREBUG_TEST_UPLINK_PROXY_PORT": ["1234"],
            "SCOREBUG_TEST_UPLINK_PROFILE": ["passthrough"], "SCOREBUG_TEST_DECODER_STALL": ["1"],
            "SCOREBUG_TEST_CADENCE_REPORTS": ["1"], "SCOREBUG_TEST_DELIVERY_DEADLINE_MS": ["1000", "1500.0"],
            "SCOREBUG_TEST_DEADLINE_RESETS": ["1"]
        ] {
            for value in values {
                var environment = valid; environment[key] = value
                XCTAssertThrowsError(try NativeMeasuredTrialFixture.requested(environment: environment), "\(key)=\(value)")
            }
        }
    }
}
