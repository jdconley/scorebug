#if DEBUG
import Foundation
import ScorebugCore

/// Explicit simulator evidence, separate from the live controller. No media or
/// credentials are retained. Teardown exports one closed, bounded attempt.
struct WorkerCadenceReportAudit {
    private var rows: [[String: Any]] = []
    private var closed = false
    private var overflow = false
    private var invalid = false
    static func requested(environment: [String: String]) -> Bool {
        environment["SCOREBUG_TEST_CADENCE_REPORTS"] == "1"
            && VideoObservationFixture.requested(environment: environment)
            && environment["SCOREBUG_TEST_LIVE_PROFILE"] == "240p30"
            && environment["SCOREBUG_TEST_MOTION_FIXTURE"] == "blocks16"
            && (environment["SCOREBUG_TEST_NATIVE_QUALITY"] ?? "").isEmpty
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    mutating func record(response: WorkerMediaStatusResponse, expectedAttempt: UUID,
                         helper: WorkerDecoderCadenceFreshness?, receivedAt: ContinuousClock.Instant,
                         requestDuration: Duration, receivedUptime: Double,
                         instant: ContinuousClock.Instant, evaluatedUptime: Double) {
        guard !closed else { return }
        guard rows.count < 2048 else { overflow = true; return }
        guard requestDuration >= .zero, instant >= receivedAt,
              receivedUptime.isFinite, evaluatedUptime.isFinite, receivedUptime >= 0,
              evaluatedUptime >= receivedUptime,
              let data = try? JSONEncoder().encode(response),
              let raw = try? JSONSerialization.jsonObject(with: data) else { invalid = true; return }
        rows.append(["response": raw, "expectedAttempt": expectedAttempt.uuidString.lowercased(),
            "receivedUptime": receivedUptime, "evaluatedUptime": evaluatedUptime,
            "requestSeconds": Self.seconds(requestDuration),
            "residenceSeconds": Self.seconds(receivedAt.duration(to: instant)),
            "sampleAgeSeconds": helper?.sampleAgeUpperBound(at: instant).map(Self.seconds) as Any? ?? NSNull(),
            "observedStall": helper?.observedStall(maximumSampleAge: .milliseconds(250), at: instant) as Any? ?? NSNull()])
    }
    mutating func close() { closed = true }
    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "closed": closed,
            "overflow": overflow, "invalid": invalid, "rows": rows], options: [.sortedKeys])
    }
    static func persist(_ data: Data) async {
        await Task.detached {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("worker-cadence-reports.json"), options: .atomic)
        }.value
    }
}
#endif
