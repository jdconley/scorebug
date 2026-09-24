import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia

/// Separate one-second floor and two-second loss lanes. These overlap each other
/// and must never both contribute recovery credit. Scheduling alone proves no
/// source ownership, freshness or deadline result.
enum PublishingDeliveryMonitor {
    #if DEBUG
    /// Explicit simulator qualification only; no production deadline default.
    static func fixtureLatencyBudget(environment: [String: String]) throws -> Double {
        if try NativeMeasuredTrialFixture.requested(environment: environment) { return 1.5 }
        guard let raw = environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] else { return 1 }
        guard ["1000", "1500"].contains(raw), WorkerCadenceReportAudit.requested(environment: environment),
              ["1", "reset540"].contains(environment["SCOREBUG_TEST_DECODER_STALL"] ?? "") else {
            throw Schedule.Failure.invalidBudget
        }
        return raw == "1500" ? 1.5 : 1
    }
    /// Downward-only qualification mode; every prerequisite is explicit.
    static func fixtureResetsRequested(environment: [String: String]) throws -> Bool {
        guard let raw = environment["SCOREBUG_TEST_DEADLINE_RESETS"] else { return false }
        guard raw == "1", environment["SCOREBUG_TEST_DELIVERY_DEADLINE_MS"] == "1500",
              ["1", "reset540"].contains(environment["SCOREBUG_TEST_DECODER_STALL"] ?? ""),
              WorkerCadenceReportAudit.requested(environment: environment) else {
            throw Schedule.Failure.invalidBudget
        }
        return true
    }
    #endif
    struct Window: Equatable, Sendable {
        let start: Double
        let end: Double
    }
    struct Schedule: Sendable {
        enum Failure: Error { case invalidBudget }
        let latencyBudget: Double
        let maximumSampleAge: Double
        private var identity: String?
        private var starts: [Double] = []
        private var previousTime: Double?
        private(set) var invalid = false

        init(latencyBudget: Double, maximumSampleAge: Double) throws {
            guard latencyBudget.isFinite, latencyBudget > 0, latencyBudget <= 10,
                  maximumSampleAge.isFinite, maximumSampleAge > 0, maximumSampleAge <= 5 else { throw Failure.invalidBudget }
            self.latencyBudget = latencyBudget; self.maximumSampleAge = maximumSampleAge
        }
        mutating func poll(at now: Double, identity next: String?) -> [Window] {
            guard !invalid else { return [] }
            guard now.isFinite, (0...1e12).contains(now), previousTime.map({ now >= $0 }) ?? true else {
                invalid = true; return []
            }
            let suspended = previousTime.map { now - $0 > 5 } ?? false
            previousTime = now
            guard let next else { identity = nil; starts = []; return [] }
            if identity != next || suspended {
                identity = next; starts = [ceil(now), ceil(now)]; return []
            }
            var result: [Window] = []
            for index in starts.indices {
                let duration = Double(index + 1), end = starts[index] + duration
                if now >= end + latencyBudget + maximumSampleAge {
                    result.append(.init(start: starts[index], end: end))
                    starts[index] = end
                }
            }
            return result
        }
    }
    struct Input: Sendable {
        let history: VideoSourceHistorySnapshot
        let clock: PublishingClockObservation
        let diagnostics: PublishingQualityTelemetry.Diagnostics
        let delivery: WorkerDecoderDeliveryFreshness
        var authority: PublishingDeliveryAuthority? = nil
    }

    /// Explicit qualification export. Legacy storage remains bounded to 256 rows;
    /// the validated repeated fixture uses a separate row and serialized-byte budget.
    /// Caller serializes access. Only the explicit deadline-reset fixture consumes results.
    final class Audit {
        private struct Key: Equatable {
            let scope: VideoFrameObservationScope
            let clock: PublishingTransportClock
            let context: WorkerDecoderDeliveryFreshness.Context
            let deliveryScope: String
            let attempt: UUID
            let revision: UInt64
            let configuration: VideoEncodingConfiguration
            let generation: UInt64
            let acceptedAt: Double
            let submittedPTS: CMTime?
            let acknowledgedAt: Double
            let authorityID: ObjectIdentifier?
        }
        private let usesRequestTiming: Bool
        private let repeated: Bool
        private static let repeatedMaximumRows = 512
        private static let repeatedMaximumBytes = 32 * 1024 * 1024
        // Include separators and reserve the fixed envelope before retaining a
        // row. Exhaustion is terminal so later smaller rows cannot hide a gap.
        private static let envelopeAllowance = 4096
        private var serializedRowBytes = 0
        private var serializationInvalid = false
        private var schedule: Schedule
        private var key: Key?
        private var phase = 0
        private var rows: [[String: Any]] = []
        private var closed = false
        private var overflow = false
        init(latencyBudget: Double, maximumSampleAge: Double, usesRequestTiming: Bool = false, environment: [String: String] = [:]) throws {
            self.usesRequestTiming = usesRequestTiming
            #if DEBUG
            repeated = environment["SCOREBUG_TEST_BANDWIDTH_PROBE"] == "repeated"
                && environment["SCOREBUG_TEST_STREAM_HOLD_SECONDS"] == "180"
                && (try? NativeMeasuredTrialFixture.requested(environment: environment)) == true
            #else
            repeated = false
            #endif
            schedule = try .init(latencyBudget: latencyBudget, maximumSampleAge: maximumSampleAge)
        }
        @discardableResult func record(input: Input?, applied: PublishingQualityTelemetry.Applied, at now: Double,
                    instant: ContinuousClock.Instant) -> [PublishingDeliveryObservation] {
            guard !closed, !overflow, !serializationInvalid else { return [] }
            guard let input else { key = nil; _ = schedule.poll(at: now, identity: nil); return [] }
            var observations: [PublishingDeliveryObservation] = []
            let next = Key(scope: input.history.scope, clock: input.clock.transportClock,
                context: input.delivery.context, deliveryScope: input.delivery.snapshot.scopeID,
                attempt: applied.attemptID, revision: applied.revision, configuration: applied.receipt.configuration,
                generation: applied.receipt.publishingGeneration, acceptedAt: applied.receipt.acceptedAt,
                submittedPTS: applied.receipt.lastSubmittedSourcePTS, acknowledgedAt: applied.acknowledgedAt,
                authorityID: input.authority.map(ObjectIdentifier.init))
            if key != next {
                guard phase < 256 else { overflow = true; return [] }
                key = next; phase += 1
            }
            for window in schedule.poll(at: now, identity: String(phase)) {
                guard rows.count < (repeated ? Self.repeatedMaximumRows : 256) else { overflow = true; return observations }
                var row: [String: Any] = ["phase": phase, "start": window.start, "end": window.end, "evaluatedAt": now,
                    "appliedRevision": String(applied.revision), "acknowledgedAt": applied.acknowledgedAt,
                    "profileID": applied.settings.profileID, "videoBitrate": applied.settings.videoBitrate,
                    "attemptID": applied.attemptID.uuidString.lowercased(), "receipt": Self.receipt(applied.receipt),
                    "deliveryReceiptID": input.delivery.receiptID.uuidString.lowercased(),
                    "sampleAgeSeconds": Self.optional(input.delivery.sampleAgeUpperBound(at: instant).map(Self.seconds)),
                    "clock": Self.clock(input.clock.transportClock), "clockClosed": input.clock.isClosed,
                    "clockScope": Self.scope(input.clock.scope), "history": NSNull(),
                    "timeline": Self.json(input.delivery.snapshot), "context": Self.context(input.delivery.context),
                    "diagnostics": ["isPublishing": input.diagnostics.isPublishing,
                        "clock": Self.optional(input.diagnostics.clock.map(Self.clock)),
                        "receipt": Self.optional(input.diagnostics.receipt.map(Self.receipt)),
                        "ingressScope": Self.optional(input.diagnostics.ingress.map { Self.scope($0.scope) }),
                        "ingressClosed": input.diagnostics.ingress?.isClosed ?? true],
                    "result": NSNull(), "reason": NSNull()]
                if usesRequestTiming {
                    row["sampleTimeBounds"] = Self.optional(input.delivery.sampleTimeBounds.map { ["lower": $0.lower, "upper": $0.upper] })
                }
                var retainedObservation: PublishingDeliveryObservation?
                do {
                    guard usesRequestTiming == (input.delivery.sampleTimeBounds != nil) else { throw PublishingDeliveryObservation.Failure.freshness }
                    let observation = try PublishingDeliveryObservation.classify(history: input.history, clock: input.clock,
                        applied: applied, diagnostics: input.diagnostics, delivery: input.delivery,
                        windowStart: window.start, windowEnd: window.end, at: now, instant: instant,
                        maximumSampleAge: schedule.maximumSampleAge, latencyBudget: schedule.latencyBudget, authority: input.authority)
                    retainedObservation = observation
                    row["classifiedAt"] = observation.classifiedAt
                    row["observedAtLowerBound"] = observation.observedAtLowerBound
                    row["anchorSourcePTS"] = Self.time(observation.source.anchorSourcePTS)
                    row["history"] = Self.history(input.history, start: window.start, anchor: observation.source.anchorSourcePTS)
                    let result = observation.result
                    row["result"] = ["expectedFrames": result.expectedFrames, "onTimeFrames": result.onTimeFrames,
                        "lateFrames": result.lateFrames, "missingFrames": result.missingFrames,
                        "uncertainFrames": result.uncertainFrames, "onTimeFPS": Self.optional(result.onTimeFPS),
                        "failureFraction": Self.optional(result.failureFraction)]
                    row["frames"] = observation.source.frames.map { ["pts": String($0.decodedPTS),
                        "sourcePTS": Self.time($0.sourcePTS), "capturedAt": $0.capturedAt, "wasEncoded": $0.wasEncoded] as [String: Any] }
                } catch {
                    row["reason"] = String(describing: error)
                    row["history"] = Self.history(input.history, start: window.start, anchor: nil)
                }
                if repeated {
                    guard JSONSerialization.isValidJSONObject(row),
                          let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    else { serializationInvalid = true; return observations }
                    let available = Self.repeatedMaximumBytes - Self.envelopeAllowance - serializedRowBytes
                    guard data.count < available else { overflow = true; return observations }
                    serializedRowBytes += data.count + 1
                }
                rows.append(row)
                // Classification grants no health unless its complete replay row
                // was retained within the selected audit's capacity.
                if let retainedObservation { observations.append(retainedObservation) }
            }
            return observations
        }
        func close() { closed = true }
        func data() throws -> Data {
            var fields: [String: Any] = ["formatVersion": 1, "closed": closed, "overflow": overflow,
                "invalid": schedule.invalid || serializationInvalid, "latencyBudget": schedule.latencyBudget,
                "maximumSampleAge": schedule.maximumSampleAge, "rows": rows]
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
        private static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        private static func seconds(_ value: Duration) -> Double {
            Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
        }
        private static func json<T: Encodable>(_ value: T) -> Any {
            guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
            return object
        }
        private static func time(_ value: CMTime) -> [String: Any] {
            ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
        }
        private static func configuration(_ value: VideoEncodingConfiguration) -> [String: Any] {
            ["id": value.id.uuidString.lowercased(), "encoderSessionID": value.encoderSessionID.uuidString.lowercased(), "bitRate": value.bitRate]
        }
        private static func receipt(_ value: PublishingBitRateChange) -> [String: Any] {
            ["generation": String(value.publishingGeneration), "configuration": configuration(value.configuration),
                "acceptedAt": value.acceptedAt, "lastSubmittedPTS": optional(value.lastSubmittedSourcePTS.map(time))]
        }
        private static func scope(_ value: VideoFrameObservationScope) -> [String: Any] {
            ["recordingID": value.recordingID, "matchID": value.matchID, "broadcastGeneration": value.broadcastGeneration,
                "publishingAttemptID": value.publishingAttemptID.uuidString.lowercased(), "appliedProfileRevision": String(value.appliedProfileRevision)]
        }
        private static func clock(_ value: PublishingTransportClock) -> [String: Any] {
            ["generation": String(value.publishingGeneration), "sourceOrigin": time(value.sourceOrigin)]
        }
        private static func context(_ value: WorkerDecoderDeliveryFreshness.Context) -> [String: Any] {
            ["gameId": value.gameId, "generation": value.generation, "workerId": value.workerId,
                "workerEpoch": value.workerEpoch, "attempt": value.attempt, "publication": json(value.publication)]
        }
        private static func history(_ value: VideoSourceHistorySnapshot, start: Double, anchor: CMTime?) -> [String: Any] {
            // Preserve the retained boundary before start and the complete tail.
            // A predecessor encode can be older than the capture predecessor.
            // Unknown results retain full bounded input for diagnosing rejection.
            // Successful results must retain an older decoder anchor during silence.
            let predecessor = value.capture.lastIndex(where: { $0.observedAt < start }) ?? 0
            let captureStart = anchor.flatMap { anchor in
                value.capture.firstIndex(where: { CMTimeCompare($0.sourcePTS, anchor) == 0 })
            }.map { min(predecessor, $0) } ?? 0
            let encodedStart = anchor == nil || value.capture.isEmpty ? 0 : value.encoded.lastIndex(where: {
                CMTimeCompare($0.sourcePTS, value.capture[captureStart].sourcePTS) <= 0
            }) ?? 0
            func frame(_ value: VideoSourceFrame) -> [String: Any] {
                ["sourcePTS": time(value.sourcePTS), "observedAt": value.observedAt,
                 "encoding": optional(value.encoding.map { ["encoderSessionID": $0.encoderSessionID.uuidString.lowercased(),
                    "configuration": optional($0.configuration.map(configuration)), "submittedAt": $0.submittedAt, "completedAt": $0.completedAt] as [String: Any] })]
            }
            return ["scope": scope(value.scope), "closed": value.isClosed,
                "invalidity": optional(value.invalidity.map { String(describing: $0) }),
                "omittedCaptureFrames": String(value.omittedCaptureFrames), "trimmedCaptureFrames": captureStart,
                "omittedEncodedFrames": String(value.omittedEncodedFrames), "trimmedEncodedFrames": encodedStart,
                "capture": value.capture.dropFirst(captureStart).map(frame), "encoded": value.encoded.dropFirst(encodedStart).map(frame)]
        }
        static func persist(_ data: Data) async {
            await Task.detached {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Scorebug/QA", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent("delivery-deadlines.json"), options: .atomic)
            }.value
        }
    }

}
