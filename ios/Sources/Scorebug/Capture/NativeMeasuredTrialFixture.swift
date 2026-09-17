#if DEBUG
enum NativeMeasuredTrialFixture {
    static func requested(environment: [String: String]) throws -> Bool {
        guard let flag = environment["SCOREBUG_TEST_MEASURED_TRIAL"] else { return false }
        guard flag == "1", environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] == "360p30",
              environment["SCOREBUG_TEST_DIRECT_RTMP_RECORDER"] == "1",
              environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] == "1500",
              try NativeCandidateHeadroomFixture.requested(environment: environment),
              ["SCOREBUG_TEST_UPLINK_PROFILE", "SCOREBUG_TEST_CADENCE_REPORTS", "SCOREBUG_TEST_DEADLINE_RESETS"]
                .allSatisfy({ (environment[$0] ?? "").isEmpty })
        else { throw VideoObservationFixture.UplinkError.invalidFixtureRoute }
        return true
    }
}
#endif
