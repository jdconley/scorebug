#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia

/// Explicit local qualification fixture. Only scalar, bounded observation state
/// crosses this boundary; setup, credentials and media are never serialized.
enum VideoObservationFixture {
    static func requested(environment: [String: String]) -> Bool {
        environment["SCOREBUG_TEST_VIDEO_OBSERVATIONS"] == "1"
    }

    static func data(for snapshot: VideoFrameObservationSnapshot, captureDetachedAt: Double) throws -> Data {
        let scope = snapshot.scope
        let object: [String: Any] = [
            "formatVersion": 1,
            "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration,
                "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)],
            "monotonicAnchor": snapshot.monotonicAnchor,
            "captureDetachedAt": captureDetachedAt,
            "windowDuration": snapshot.windowDuration,
            "current": window(snapshot.current),
            "completed": snapshot.completed.map(window),
            "omittedCompletedWindowCount": String(snapshot.omittedCompletedWindowCount),
            "omittedThroughMonotonicTime": optional(snapshot.omittedThroughMonotonicTime),
            "rejectedClockOperationCount": String(snapshot.rejectedClockOperationCount),
            "invalidity": snapshot.invalidity.rawValue,
            "isClosed": snapshot.isClosed,
        ]
        // JSONSerialization rejects nonfinite numbers. Optional values are explicit
        // nulls; counters, profile revision and CMTime value/epoch use decimal strings.
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private static func time(_ value: CMTime?) -> Any {
        guard let value else { return NSNull() }
        return ["value": String(value.value), "timescale": value.timescale,
            "epoch": String(value.epoch), "flags": value.flags.rawValue] as [String: Any]
    }

    private static func aggregate(_ value: VideoFrameObservationAggregate) -> [String: Any] {
        ["callbackCount": String(value.callbackCount),
         "advancingSourcePTSCount": String(value.advancingSourcePTSCount),
         "duplicateSourcePTSCount": String(value.duplicateSourcePTSCount),
         "reorderedSourcePTSCount": String(value.reorderedSourcePTSCount),
         "invalidSourcePTSCount": String(value.invalidSourcePTSCount),
         "discontinuousSourcePTSCount": String(value.discontinuousSourcePTSCount),
         "firstSourcePTS": time(value.firstSourcePTS), "lastSourcePTS": time(value.lastSourcePTS),
         "highWaterSourcePTS": time(value.highWaterSourcePTS),
         "firstObservationTime": optional(value.firstObservationTime),
         "lastObservationTime": optional(value.lastObservationTime),
         "invalidity": value.invalidity.rawValue]
    }

    private static func window(_ value: VideoFrameObservationWindow) -> [String: Any] {
        ["monotonicStart": value.monotonicStart, "monotonicEnd": value.monotonicEnd,
         "scheduledMonotonicEnd": value.scheduledMonotonicEnd,
         "coveredWindowCount": String(value.coveredWindowCount),
         "isCoalescedEmptyGap": value.isCoalescedEmptyGap, "isPartial": value.isPartial,
         "isClosed": value.isClosed, "captureVideo": aggregate(value.captureVideo),
         "encodedVideo": aggregate(value.encodedVideo)]
    }

    #if targetEnvironment(simulator)
    /// Awaited by the existing teardown task after encoder drain and identity
    /// admission. This single I/O task is joined before another attempt can start.
    /// Failure cannot interrupt teardown; a missing artifact fails the runner.
    static func writeClosed(_ snapshot: VideoFrameObservationSnapshot, captureDetachedAt: Double) async {
        guard snapshot.isClosed else { return }
        await Task.detached(priority: .utility) {
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent("Scorebug/QA", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data(for: snapshot, captureDetachedAt: captureDetachedAt).write(to: directory.appendingPathComponent("video-observation.json"), options: .atomic)
            } catch {
                // Qualification is optional to capture and archive cleanup.
            }
        }.value
    }
    #endif
}
#endif
