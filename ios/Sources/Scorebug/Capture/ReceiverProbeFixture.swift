#if DEBUG
import Foundation
import ScorebugCore
import ScorebugMedia

/// Bounded evidence of the actual app tracker, exported only by the opt-in fixture.
struct ReceiverProbeFixtureHistory {
    private var rows: [[String: Any]] = []
    private var keys: Set<String> = []
    private var invalid = false
    mutating func record(_ interval: WorkerReceiverProbeInterval?, accepted: PublishingProbeObservation,
                         at instant: ContinuousClock.Instant, timing: PublishingProbeReadTiming, quarantined: Bool) {
        invalid = invalid || quarantined
        guard let interval else { return }
        let end = interval.end
        let key = "\(end.workerEpoch)/\(end.workerAttempt)/\(end.publication.readerId)/\(end.snapshot.id)/\(end.snapshot.observedAtNanoseconds)"
        guard !keys.contains(key) else { return }
        guard rows.count < 128 else { invalid = true; return }
        guard let age = end.snapshotAgeUpperBound(at: instant), let deliveryAge = end.lastDeliveryAgeUpperBound(at: instant),
              age <= WorkerReceiverProbeTracker.maximumAge, deliveryAge <= WorkerReceiverProbeTracker.maximumAge else { return }
        do {
            func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
            let parts = interval.duration.components
            rows.append([
                "start": try object(interval.start), "end": try object(end.snapshot),
                "publication": try object(end.publication), "workerEpoch": end.workerEpoch,
                "workerAttempt": end.workerAttempt, "workerId": end.expected.workerId,
                "durationNanoseconds": String(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000),
                "deliveredMessages": String(interval.deliveredMessages),
                "deliveredPayloadBytesLowerBound": String(interval.deliveredPayloadBytesLowerBound),
                "payloadBitsPerSecondLowerBound": interval.payloadBitsPerSecondLowerBound,
                "serverAgeUpperBoundMs": end.serverAgeUpperBoundMs,
                "requestDurationMs": Self.milliseconds(end.requestStartedAt.duration(to: end.receivedAt)),
                "residenceDurationMs": Self.milliseconds(end.receivedAt.duration(to: instant)),
                "requestStartedAt": timing.requestStartedAt, "responseReceivedAt": timing.responseReceivedAt,
                "nativeReadStartedAt": timing.nativeReadStartedAt, "nativeReadFinishedAt": timing.nativeReadFinishedAt,
                "evaluatedAt": timing.evaluatedAt,
                "nativeStartedAt": accepted.startedAt, "nativeLeaseDeadline": accepted.leaseDeadline,
                "nativeLastAcceptedAt": accepted.lastAcceptedAt as Any? ?? NSNull(),
                "snapshotAgeUpperBoundMs": Self.milliseconds(age), "lastDeliveryAgeUpperBoundMs": Self.milliseconds(deliveryAge),
                "acceptedPayloadBytes": String(accepted.acceptedPayloadBytes),
                "nativeProbeId": accepted.id.uuidString.lowercased(), "nativePublishingGeneration": String(accepted.publishingGeneration),
            ])
            keys.insert(key)
        } catch { invalid = true }
    }
    func data(scope: VideoFrameObservationScope) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "isClosed": true, "invalid": invalid,
            "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)], "intervals": rows], options: [.sortedKeys])
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func persist(_ data: Data) async {
        await Task.detached(priority: .utility) {
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Scorebug/QA", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("native-receiver-intervals.json"), options: .atomic)
            } catch { /* Missing evidence fails the fixture, never the recording. */ }
        }.value
    }
}
#endif
