#if DEBUG
import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia

/// Explicit local qualification fixture. Only scalar, bounded observation state
/// crosses this boundary; setup, credentials and media are never serialized.
enum VideoObservationFixture {
    enum ExportError: Error { case publishingClockScopeMismatch, publishingClockClosureMismatch, sourceIntervalMismatch }

    static func requested(environment: [String: String]) -> Bool {
        environment["SCOREBUG_TEST_VIDEO_OBSERVATIONS"] == "1"
    }

    static func completedWindowLimit(environment: [String: String]) -> Int {
        guard requested(environment: environment),
              let raw = environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"],
              let hold = Int(raw), String(hold) == raw, (12...600).contains(hold)
        else { return 8 }
        return hold > 180 ? 128 : 64
    }

    static func data(for snapshot: VideoFrameObservationSnapshot, captureDetachedAt: Double, workerReportAgeProofs: [WorkerReportAgeProof] = [], ingressObservation: LiveIngressObservationSnapshot? = nil, publishingClockObservation: PublishingClockObservation? = nil, sourceIntervals: [WorkerSourceIntervalObservation] = []) throws -> Data {
        if let publishingClockObservation {
            guard publishingClockObservation.scope == snapshot.scope else { throw ExportError.publishingClockScopeMismatch }
            guard publishingClockObservation.isClosed == snapshot.isClosed else { throw ExportError.publishingClockClosureMismatch }
        }
        let scope = snapshot.scope
        var object: [String: Any] = [
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
        if let publishingClockObservation {
            object["publishingClockObservation"] = clock(publishingClockObservation)
        }
        if let ingressObservation {
            object["ingressObservation"] = ingress(ingressObservation)
        }
        if !workerReportAgeProofs.isEmpty {
            object["workerReportAgeProofs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workerReportAgeProofs))
        }
        if !sourceIntervals.isEmpty {
            guard sourceIntervals.count <= 128 else { throw ExportError.sourceIntervalMismatch }
            object["sourceIntervals"] = try sourceIntervals.map { observation -> [String: Any] in
                let interval = observation.interval
                guard interval.scope == snapshot.scope,
                      observation.nativeClock == publishingClockObservation?.transportClock else {
                    throw ExportError.sourceIntervalMismatch
                }
                var row: [String: Any] = ["scope": object["scope"]!, "workerId": observation.workerId,
                    "workerEpoch": observation.workerEpoch, "workerAttempt": observation.workerAttempt,
                    "publication": try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation.publication)),
                    "previousSequence": String(observation.previousSequence), "sequence": String(observation.sequence),
                    "previousDecodedPTS": String(observation.previousDecodedPTS),
                    "firstDecodedPTS": String(observation.firstDecodedPTS), "lastDecodedPTS": String(observation.lastDecodedPTS),
                    "publishingGeneration": String(interval.publishingGeneration),
                    "sourceStartExclusive": time(interval.sourceStartExclusive), "sourceEndInclusive": time(interval.sourceEndInclusive),
                    "captureBoundaryStartTime": interval.captureBoundaryStartTime,
                    "captureBoundaryEndTime": interval.captureBoundaryEndTime,
                    "capturedFrames": interval.capturedFrames, "encodedFrames": interval.encodedFrames,
                    "decodedFrames": interval.decodedFrames, "captureNotEncodedFrames": interval.captureNotEncodedFrames,
                    "encodedNotDecodedFrames": interval.encodedNotDecodedFrames,
                    "leadingMissingEncodedFrames": interval.leadingMissingEncodedFrames]
                if let processing = observation.processing {
                    row["processing"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(processing))
                }
                return row
            }
        }
        // JSONSerialization rejects nonfinite numbers. Optional values are explicit
        // nulls; counters, profile revision and CMTime value/epoch use decimal strings.
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func clock(_ observation: PublishingClockObservation) -> [String: Any] {
        let scope = observation.scope
        let descriptor = observation.transportClock
        return ["scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                    "broadcastGeneration": scope.broadcastGeneration,
                    "publishingAttemptID": scope.publishingAttemptID.uuidString,
                    "appliedProfileRevision": String(scope.appliedProfileRevision)],
                "isClosed": observation.isClosed,
                "sourceOrigin": time(descriptor.sourceOrigin),
                "publishingGeneration": String(descriptor.publishingGeneration),
                "timescale": PublishingTransportClock.timescale,
                "presentationLead": String(PublishingTransportClock.presentationLead),
                "wireModulus": String(PublishingTransportClock.wireModulus)]
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

    private static func occupancy(_ value: LiveIngressOccupancy) -> [String: Any] {
        ["knownDuration": value.knownDuration, "unknownDuration": value.unknownDuration,
         "itemSeconds": value.itemSeconds, "byteSeconds": value.byteSeconds,
         "maxPressureSeconds": value.maxPressureSeconds,
         "peakItems": value.peakItems, "peakBytes": value.peakBytes]
    }

    private static func dispositionKey(_ value: LiveIngressDisposition) -> String {
        switch value {
        case .admitted: "admitted"
        case .dequeued: "dequeued"
        case .overflowEvicted: "overflowEvicted"
        case .cancellationDiscarded: "cancellationDiscarded"
        case .rejected(let reason): "rejected.\(reason.rawValue)"
        }
    }

    private static func dispositions(_ values: LiveIngressDispositions) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: values.map { disposition, kinds in
            (dispositionKey(disposition), Dictionary(uniqueKeysWithValues: kinds.map { kind, value in
                (kind.rawValue, ["count": String(value.count), "invalidPTSCount": String(value.invalidPTSCount),
                    "firstSourcePTS": time(value.firstSourcePTS), "lastSourcePTS": time(value.lastSourcePTS),
                    "minimumSourcePTS": time(value.minimumSourcePTS), "maximumSourcePTS": time(value.maximumSourcePTS),
                    "invalidity": value.invalidity.rawValue] as [String: Any])
            }) as Any)
        })
    }

    private static func window(_ value: LiveIngressObservationWindow) -> [String: Any] {
        ["monotonicStart": value.monotonicStart, "monotonicEnd": value.monotonicEnd,
         "scheduledMonotonicEnd": value.scheduledMonotonicEnd,
         "coveredWindowCount": String(value.coveredWindowCount), "isCoalesced": value.isCoalesced,
         "isPartial": value.isPartial, "isClosed": value.isClosed,
         "occupancy": occupancy(value.occupancy),
         "occupancyByPhase": Dictionary(uniqueKeysWithValues: value.occupancyByPhase.map { ($0.key.rawValue, occupancy($0.value)) }),
         "dispositions": dispositions(value.dispositions)]
    }

    private static func ingress(_ value: LiveIngressObservationSnapshot) -> [String: Any] {
        let scope = value.scope
        return ["formatVersion": 1,
            "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                "broadcastGeneration": scope.broadcastGeneration,
                "publishingAttemptID": scope.publishingAttemptID.uuidString,
                "appliedProfileRevision": String(scope.appliedProfileRevision)],
            "monotonicAnchor": value.monotonicAnchor, "windowDuration": value.windowDuration,
            "maxItems": value.maxItems, "maxBytes": value.maxBytes,
            "phase": value.phase.rawValue, "currentItems": value.currentItems, "currentBytes": value.currentBytes,
            "current": window(value.current), "completed": value.completed.map(window),
            "totalOccupancy": occupancy(value.totalOccupancy), "totalDispositions": dispositions(value.totalDispositions),
            "omittedCompletedWindowCount": String(value.omittedCompletedWindowCount),
            "omittedThroughMonotonicTime": optional(value.omittedThroughMonotonicTime),
            "rejectedClockOperationCount": String(value.rejectedClockOperationCount),
            "unassignedDispositionCount": String(value.unassignedDispositionCount),
            "invalidity": value.invalidity.rawValue, "isClosed": value.isClosed]
    }

    #if targetEnvironment(simulator)
    /// Awaited by the existing teardown task after encoder drain and identity
    /// admission. This single I/O task is joined before another attempt can start.
    /// Failure cannot interrupt teardown; a missing artifact fails the runner.
    static func writeClosed(_ snapshot: VideoFrameObservationSnapshot, captureDetachedAt: Double, workerReportAgeProofs: [WorkerReportAgeProof] = [], ingressObservation: LiveIngressObservationSnapshot? = nil, publishingClockObservation: PublishingClockObservation? = nil, sourceIntervals: [WorkerSourceIntervalObservation] = []) async {
        guard snapshot.isClosed else { return }
        await Task.detached(priority: .utility) {
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent("Scorebug/QA", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data(for: snapshot, captureDetachedAt: captureDetachedAt, workerReportAgeProofs: workerReportAgeProofs, ingressObservation: ingressObservation, publishingClockObservation: publishingClockObservation, sourceIntervals: sourceIntervals).write(to: directory.appendingPathComponent("video-observation.json"), options: .atomic)
            } catch {
                // Qualification is optional to capture and archive cleanup.
            }
        }.value
    }
    #endif
}

/// Historical scalar evidence of the helper return at a single poll evaluation.
/// This never evaluates freshness again during export.
struct WorkerReportAgeProof: Encodable, Equatable, Sendable {
    struct ExactDuration: Encodable, Equatable, Sendable {
        let seconds: String
        let attoseconds: String
        init(_ value: Duration) {
            seconds = String(value.components.seconds)
            attoseconds = String(value.components.attoseconds)
        }
    }
    let recordingID: String
    let publishingAttemptID: String
    let gameId: String
    let generation: Int
    let workerId: String
    let attempt: Int
    let completed: DecodedVideoWindow
    let decodedVideoAgeUpperBoundMs: Int64
    let requestDuration: ExactDuration
    let residenceDuration: ExactDuration
    let helperAgeUpperBound: ExactDuration
    let evaluatedAt = "pollControl"
    let ended = false
    let invalidReason: String? = nil

    init?(scope: VideoFrameObservationScope, helper: WorkerDecodedVideoFreshness?,
          serverUpperBoundMs: Double?, requestDuration: Duration,
          residenceDuration: Duration, helperAgeUpperBound: Duration?) {
        guard let helper, let serverUpperBoundMs, let helperAgeUpperBound,
              scope.matchID == helper.gameId, scope.broadcastGeneration == helper.generation,
              serverUpperBoundMs.isFinite, serverUpperBoundMs >= 0,
              serverUpperBoundMs.rounded(.towardZero) == serverUpperBoundMs,
              serverUpperBoundMs <= 9_007_199_254_740_991,
              requestDuration >= .zero, residenceDuration >= .zero,
              helperAgeUpperBound >= .zero else { return nil }
        recordingID = scope.recordingID; publishingAttemptID = scope.publishingAttemptID.uuidString
        gameId = helper.gameId; generation = helper.generation; workerId = helper.workerId
        attempt = helper.attempt; completed = helper.completed
        decodedVideoAgeUpperBoundMs = Int64(serverUpperBoundMs)
        self.requestDuration = ExactDuration(requestDuration)
        self.residenceDuration = ExactDuration(residenceDuration)
        self.helperAgeUpperBound = ExactDuration(helperAgeUpperBound)
    }

    // Explicit null remains distinguishable from a missing decoder-validity field.
    enum CodingKeys: String, CodingKey {
        case recordingID, publishingAttemptID, gameId, generation, workerId, attempt, completed
        case decodedVideoAgeUpperBoundMs, requestDuration, residenceDuration, helperAgeUpperBound
        case evaluatedAt, ended, invalidReason
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordingID, forKey: .recordingID)
        try c.encode(publishingAttemptID, forKey: .publishingAttemptID)
        try c.encode(gameId, forKey: .gameId); try c.encode(generation, forKey: .generation)
        try c.encode(workerId, forKey: .workerId); try c.encode(attempt, forKey: .attempt)
        try c.encode(completed, forKey: .completed)
        try c.encode(decodedVideoAgeUpperBoundMs, forKey: .decodedVideoAgeUpperBoundMs)
        try c.encode(requestDuration, forKey: .requestDuration)
        try c.encode(residenceDuration, forKey: .residenceDuration)
        try c.encode(helperAgeUpperBound, forKey: .helperAgeUpperBound)
        try c.encode(evaluatedAt, forKey: .evaluatedAt); try c.encode(ended, forKey: .ended)
        try c.encode(invalidReason, forKey: .invalidReason)
    }
}

struct WorkerReportAgeProofHistory {
    private(set) var proofs: [WorkerReportAgeProof] = []
    mutating func record(_ proof: WorkerReportAgeProof?) {
        guard let proof else { clear(); return }
        if let newest = proofs.last {
            if newest.recordingID != proof.recordingID || newest.publishingAttemptID != proof.publishingAttemptID ||
                newest.gameId != proof.gameId || newest.generation != proof.generation ||
                newest.workerId != proof.workerId || newest.attempt != proof.attempt ||
                proof.completed.sequence < newest.completed.sequence {
                clear()
            } else if proof.completed.sequence == newest.completed.sequence {
                proofs[proofs.count - 1] = proof
                return
            }
        }
        proofs.append(proof)
        if proofs.count > 2 { proofs.removeFirst() }
    }
    mutating func clear() { proofs = [] }
}
#endif
