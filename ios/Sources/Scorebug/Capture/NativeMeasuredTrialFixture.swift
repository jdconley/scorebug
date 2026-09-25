#if DEBUG
enum NativeMeasuredTrialFixture {
    static func probePolicy(environment: [String: String]) throws -> PublishingProbeObservation.Policy {
        guard let raw = environment["SCOREBUG_TEST_PROBE_POLICY"], !raw.isEmpty else { return .localZeroLoss }
        guard raw == "recovery-budget-v1",
              VideoObservationFixture.measuredFileUplink(environment: environment),
              try VideoObservationFixture.liveProfile(environment: environment) == .low240
        else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return .recoveryBudget
    }

    static func requested(environment: [String: String]) throws -> Bool {
        _ = try probePolicy(environment: environment)
        guard let flag = environment["SCOREBUG_TEST_MEASURED_TRIAL"] else { return false }
        guard flag == "1", environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] == "360p30",
              environment["SCOREBUG_TEST_DIRECT_RTMP_RECORDER"] == "1",
              environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] == "1500",
              try NativeCandidateHeadroomFixture.requested(environment: environment),
              ((environment["SCOREBUG_TEST_UPLINK_PROFILE"] ?? "").isEmpty || VideoObservationFixture.measuredFileUplink(environment: environment)),
              ["SCOREBUG_TEST_CADENCE_REPORTS", "SCOREBUG_TEST_DEADLINE_RESETS"]
                .allSatisfy({ (environment[$0] ?? "").isEmpty })
        else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return true
    }
}
#endif
