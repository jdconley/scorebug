#if DEBUG
import Foundation
import ScorebugCore

/// Explicit simulator evidence, separate from the live controller. No media or
/// credentials are retained. Teardown exports one closed, bounded attempt.
struct WorkerCadenceReportAudit {
    struct StageTiming {
        let controlStartedUptime: Double
        let statusRequestStartedUptime: Double
        let responseReceivedUptime: Double
        let probeReadStartedUptime: Double
        let probeReadFinishedUptime: Double
        let auditEvaluatedUptime: Double

        fileprivate func fields(receivedUptime: Double, evaluatedUptime: Double) -> [String: Double]? {
            let instants = [controlStartedUptime, statusRequestStartedUptime, responseReceivedUptime,
                probeReadStartedUptime, probeReadFinishedUptime, auditEvaluatedUptime]
            guard instants.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  zip(instants, instants.dropFirst()).allSatisfy({ $0 <= $1 }),
                  responseReceivedUptime == receivedUptime, auditEvaluatedUptime == evaluatedUptime else { return nil }
            return ["controlStartedUptime": controlStartedUptime,
                "statusRequestStartedUptime": statusRequestStartedUptime,
                "responseReceivedUptime": responseReceivedUptime,
                "probeReadStartedUptime": probeReadStartedUptime,
                "probeReadFinishedUptime": probeReadFinishedUptime,
                "auditEvaluatedUptime": auditEvaluatedUptime,
                "maintenanceSeconds": statusRequestStartedUptime - controlStartedUptime,
                "statusHTTPSeconds": responseReceivedUptime - statusRequestStartedUptime,
                "responseProcessingSeconds": probeReadStartedUptime - responseReceivedUptime,
                "nativeProbeSeconds": probeReadFinishedUptime - probeReadStartedUptime,
                "postProbeProcessingSeconds": auditEvaluatedUptime - probeReadFinishedUptime]
        }
    }
    private let usesRequestTiming: Bool
    private let repeated: Bool
    private static let repeatedMaximumRows = 3072
    private static let repeatedMaximumBytes = 16 * 1024 * 1024
    // Reserve space for the small envelope and separators. Overflow is terminal:
    // retaining a later smaller row would hide a gap in the original history.
    private static let envelopeAllowance = 4096
    private var serializedRowBytes = 0
    init(usesRequestTiming: Bool = false, environment: [String: String] = [:]) {
        self.usesRequestTiming = usesRequestTiming
        repeated = environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] == "repeated"
            && environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] == "180"
            && (try? NativeMeasuredTrialFixture.requested(environment: environment)) == true
    }
    private var rows: [[String: Any]] = []
    private var closed = false
    private var overflow = false
    private var invalid = false
    static func requested(environment: [String: String]) -> Bool {
        if (try? NativeMeasuredTrialFixture.requested(environment: environment)) == true { return true }
        return environment["SCOREBUG_TEST_CADENCE_REPORTS"] == "1"
            && VideoObservationFixture.requested(environment: environment)
            && environment["SCOREBUG_TEST_LIVE_PROFILE"] == "240p30"
            && environment["SCOREBUG_TEST_MOTION_FIXTURE"] == "blocks16"
            && (environment["SCOREBUG_TEST_NATIVE_QUALITY"] ?? "").isEmpty
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    mutating func record(response: WorkerMediaStatusResponse, expectedAttempt: UUID,
                         helper: WorkerDecoderCadenceFreshness?, delivery: WorkerDecoderDeliveryFreshness? = nil, receivedAt: ContinuousClock.Instant,
                         requestDuration: Duration, receivedUptime: Double,
                         instant: ContinuousClock.Instant, evaluatedUptime: Double, timing: StageTiming? = nil) {
        guard !closed, !overflow else { return }
        guard rows.count < (repeated ? Self.repeatedMaximumRows : 2048) else { overflow = true; return }
        guard requestDuration >= .zero, instant >= receivedAt,
              receivedUptime.isFinite, evaluatedUptime.isFinite, receivedUptime >= 0,
              evaluatedUptime >= receivedUptime,
              let data = try? JSONEncoder().encode(response),
              let raw = try? JSONSerialization.jsonObject(with: data) else { invalid = true; return }
        let fields = timing?.fields(receivedUptime: receivedUptime, evaluatedUptime: evaluatedUptime)
        guard (timing == nil || fields != nil), (!usesRequestTiming || fields != nil),
              usesRequestTiming || delivery?.sampleTimeBounds == nil else { invalid = true; return }
        var row: [String: Any] = ["response": raw, "expectedAttempt": expectedAttempt.uuidString.lowercased(),
            "receivedUptime": receivedUptime, "evaluatedUptime": evaluatedUptime,
            "requestSeconds": Self.seconds(requestDuration),
            "residenceSeconds": Self.seconds(receivedAt.duration(to: instant)),
            "cadenceReceiptID": helper?.receiptID.uuidString.lowercased() as Any? ?? NSNull(),
            "deliveryReceiptID": delivery?.receiptID.uuidString.lowercased() as Any? ?? NSNull(),
            "deliverySampleAgeSeconds": delivery?.sampleAgeUpperBound(at: instant).map(Self.seconds) as Any? ?? NSNull(),
            "sampleAgeSeconds": helper?.sampleAgeUpperBound(at: instant).map(Self.seconds) as Any? ?? NSNull(),
            "observedStall": helper?.observedStall(maximumSampleAge: .milliseconds(250), at: instant) as Any? ?? NSNull()]
        if usesRequestTiming {
            row["deliverySampleTimeBounds"] = delivery?.sampleTimeBounds.map { ["lower": $0.lower, "upper": $0.upper] } as Any? ?? NSNull()
        }
        if let fields { row["timing"] = fields }
        if repeated {
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            else { invalid = true; return }
            let available = Self.repeatedMaximumBytes - Self.envelopeAllowance - serializedRowBytes
            guard data.count < available else { overflow = true; return }
            serializedRowBytes += data.count + 1
        }
        rows.append(row)
    }
    mutating func close() { closed = true }
    func data() throws -> Data {
        var fields: [String: Any] = ["formatVersion": 1, "closed": closed,
            "overflow": overflow, "invalid": invalid, "rows": rows]
        if usesRequestTiming { fields["deliveryTiming"] = "request-uptime-v1" }
        if repeated {
            fields["formatVersion"] = 2
            fields["mode"] = "repeated"
            fields["maximumRows"] = Self.repeatedMaximumRows
            fields["maximumBytes"] = Self.repeatedMaximumBytes
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard !repeated || data.count <= Self.repeatedMaximumBytes else { throw ExportError.capacity }
        return data
    }
    private enum ExportError: Error { case capacity }
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
