import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import ScorebugStreaming
import XCTest

final class PublishingQualityTelemetryTests: XCTestCase {
    typealias Adapter = PublishingQualityTelemetry
    private let attempt = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let epoch = "22222222-2222-2222-2222-222222222222"
    private let config = VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 2_000_000)!
    private let now = ContinuousClock.now
    private var workerLimits: Adapter.WorkerLimits { .init(encoder: "videotoolbox", maximumFilterMs: 250, maximumProcessingMs: 1000)! }
    private var transportLimits: Adapter.TransportLimits { .init(maximumBufferMs: 500, maximumRTTMs: 500, maximumRetransmittedFraction: 0.01)! }
    private var scope: VideoFrameObservationScope {
        .init(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
              publishingAttemptID: attempt, appliedProfileRevision: 1)
    }
    struct Fixture {
        var source: WorkerSourceIntervalObservation
        var applied: Adapter.Applied
        var diagnostics: Adapter.Diagnostics
        var now: Double = 110.5
    }
    private func fixture(configurations: [Int: VideoEncodingConfiguration?] = [:],
                         missingEncoded: Set<Int> = [], decodedCount: Int64 = 150,
                         thermalState: PublishingThermalState = .nominal,
                         retransmitted: UInt64 = 0, drops: Int32 = 0, buffer: Int32 = 0,
                         rtt: Double = 10, delay: Int32? = nil, frameOffset: Int = 0, workerEpoch: String? = nil,
                         windowSequence: Int64 = 2, encodingConfiguration: VideoEncodingConfiguration? = nil,
                         receivedAt: ContinuousClock.Instant? = nil) throws -> Fixture {
        let config = encodingConfiguration ?? self.config
        var history = try VideoSourceHistory(scope: scope, capacity: 1024)
        for i in 0...330 {
            let time = 100 + Double(i + frameOffset) / 30, pts = CMTime(value: Int64(i + frameOffset), timescale: 30)
            history.observe(.captureVideo, sourcePTS: pts, at: time)
            if !missingEncoded.contains(i) {
                let configuration = configurations.keys.contains(i) ? configurations[i]! : config
                let encoding = VideoEncodingObservation(encoderSessionID: configuration?.encoderSessionID ?? config.encoderSessionID,
                    configuration: configuration, submittedAt: time, completedAt: time + 0.01)!
                history.observe(.encodedVideo, sourcePTS: pts, at: time + 0.01, encoding: encoding)
            }
        }
        let clock = PublishingTransportClock(sourceOrigin: .zero, publishingGeneration: 7)!
        let publication = WorkerPublication(readerId: "33333333-3333-3333-3333-333333333333",
            publisherId: "44444444-4444-4444-4444-444444444444", publishingAttemptId: attempt.uuidString.lowercased(),
            clock: .init(convention: "mpegts-ingress-origin-90k-v1", originPTS: "10919"))
        func response(_ sequence: Int64) -> WorkerMediaStatusResponse {
            let position = sequence - windowSequence + 2
            let first = (position - 1) * 150 + Int64(frameOffset), end = position * 150 - 1 + Int64(frameOffset)
            let w = DecodedVideoWindow(sequence: sequence, durationMs: 5000, ageMs: 100,
                firstPTS: first * 3000 - 1919, lastPTS: end * 3000 - 1919,
                freshFrames: sequence == windowSequence ? decodedCount : 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
            var observation = WorkerObservation(gameId: "match", generation: 1, state: .producingOutput, reason: nil,
                attempt: 1, frame: 300, outTimeUs: 10_000_000, scoreRevision: 1,
                decodedVideo: .init(completed: w, invalidReason: nil, ended: false, clock: "mpegts-pts-90k-v1"))
            if sequence == windowSequence {
                observation.processing = .init(scopeID: "55555555-5555-5555-5555-555555555555", encoder: "videotoolbox",
                    previousSequence: sequence - 1, sequence: sequence, firstPTS: w.firstPTS!,
                    interval: .init(sourceStartExclusive: Int64(149 + frameOffset) * 3000 - 1919, sourceEndInclusive: w.lastPTS!,
                        decodedFrames: decodedCount, submittedFrames: decodedCount, completedFrames: decodedCount,
                        pendingFrames: 0, omittedBeforeEncoderFrames: 0,
                        filterDuration: .init(meanMs: 1, maximumMs: 4), processingDuration: .init(meanMs: 400, maximumMs: 430)))
            }
            return .init(status: .init(gameId: "match", generation: 1, workerId: "mac", state: .producingOutput,
                observation: observation, observedAt: "2040-01-01T00:00:00Z", expiresAt: "2040-01-01T00:00:05Z",
                decodedVideoAgeUpperBoundMs: 200, workerEpoch: workerEpoch ?? epoch, publication: publication), serverTime: "2040-01-01T00:00:00Z")
        }
        var tracker = WorkerSourceIntervalTracker()
        let mapping = PublishingClockObservation(scope: scope, transportClock: clock, isClosed: false)
        _ = tracker.observe(response: response(windowSequence - 1), history: history.snapshot, clock: mapping, receivedAt: receivedAt ?? now, requestDuration: .milliseconds(50))
        let source = try XCTUnwrap(tracker.observe(response: response(windowSequence), history: history.snapshot, clock: mapping,
            receivedAt: receivedAt ?? now, requestDuration: .milliseconds(50)))
        let receipt = PublishingBitRateChange(publishingGeneration: 7, configuration: config, acceptedAt: 100,
            lastSubmittedSourcePTS: .zero)!
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        ingress.updateOccupancy(items: 1, bytes: 10, phase: .admitting, at: 100)
        var transport = PublishingTransportStatisticsTracker(), thermal = PublishingThermalTracker()
        for i in 0...(11 + frameOffset / 30) {
            let t = 100 + Double(i)
            transport.observe(.init(publishingGeneration: 7, sampledAt: t, elapsedMilliseconds: Int64(i * 1000),
                sentBytes: UInt64(i * 10000), retransmittedBytes: UInt64(i) * retransmitted,
                droppedPackets: Int32(i) * drops, rttMilliseconds: rtt, estimatedBandwidthMbps: 999,
                senderBufferedBytes: buffer * 100, senderBufferMilliseconds: buffer, availableSenderBytes: 10000, senderDeliveryDelayMilliseconds: delay))
            thermal.observe(.init(state: thermalState, sampledAt: t))
        }
        return .init(source: source, applied: .init(attemptID: attempt, revision: 0,
            settings: .init(profileID: "hd", videoBitrate: config.bitRate), receipt: receipt, acknowledgedAt: 100.1),
            diagnostics: .init(isPublishing: true, clock: clock, receipt: receipt, ingress: ingress.poll(at: 111 + Double(frameOffset) / 30),
                transport: transport.snapshot, thermal: thermal.snapshot), now: 111 + Double(frameOffset) / 30)
    }
    private func window(_ f: Fixture, instant: ContinuousClock.Instant? = nil,
                        worker: Adapter.WorkerLimits? = nil, transport: Adapter.TransportLimits? = nil) throws -> QualityController.Window {
        try Adapter.window(source: f.source, applied: f.applied, diagnostics: f.diagnostics,
            workerLimits: worker ?? workerLimits, transportLimits: transport ?? transportLimits,
            at: f.now, instant: instant ?? now)
    }
    private func local(_ f: Fixture, after: Double? = nil, limits: Adapter.TransportLimits? = nil) throws -> QualityController.Window? {
        try Adapter.localPressureWindow(applied: f.applied, diagnostics: f.diagnostics,
            transportLimits: limits ?? transportLimits, sequence: 7, after: after, at: f.now)
    }
    private var recoveryLimits: Adapter.TransportLimits {
        .init(maximumBufferMs: 500, maximumRTTMs: 500,
              maximumRetransmittedFraction: 0.01, usesSenderRecoveryBudget: true)!
    }
    func testQuarterSecondPressureDoesNotWaitForOneSecondAfterAck() throws {
        var f = try fixture(buffer: 501)
        f.applied.acknowledgedAt = 110
        let w = try XCTUnwrap(local(f, after: 110.75))
        XCTAssertEqual(w.start, 110.75); XCTAssertEqual(w.end, 111)
        XCTAssertNil(try local(f, after: 110.750001))
        f.applied.acknowledgedAt = 110.000001
        XCTAssertNil(try local(f), "Enclosing collection still predates acknowledgment")
    }
    func testRecoveryBudgetDetectsRTTBeforeFixed500msThreshold() throws {
        let f = try fixture(rtt: 31, delay: 120)
        XCTAssertNil(try local(f))
        XCTAssertEqual(try local(f, limits: recoveryLimits)?.transportPressure, .elevated)
        XCTAssertEqual(try window(f, transport: recoveryLimits).transportPressure, .elevated)
        XCTAssertEqual(try window(fixture(rtt: 30, delay: 120), transport: recoveryLimits).transportPressure, .nominal)
    }
    func testMissingRecoveryBudgetCannotEstablishHealthyTransportButRetainsKnownPressure() throws {
        for delay: Int32? in [nil, 0] {
            XCTAssertEqual(try window(fixture(delay: delay), transport: recoveryLimits).transportPressure, .unknown)
            XCTAssertNil(try local(fixture(delay: delay), limits: recoveryLimits))
            XCTAssertEqual(try local(fixture(buffer: 501, delay: delay), limits: recoveryLimits)?.transportPressure, .elevated)
        }
    }

    func testRecoveryBudgetUsesEachSamplesOwnDelayAndStillHonorsCallerCeiling() throws {
        var f = try fixture()
        for mixedUnknown in [false, true] {
            var transport = PublishingTransportStatisticsTracker()
            for i in 0...11 {
                let high = i % 2 == 0
                transport.observe(.init(publishingGeneration: 7, sampledAt: 100 + Double(i),
                    elapsedMilliseconds: Int64(i * 1000), sentBytes: UInt64(i * 10000),
                    retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: high ? 500 : 30,
                    estimatedBandwidthMbps: 999, senderBufferedBytes: 0, senderBufferMilliseconds: 0,
                    availableSenderBytes: 10000,
                    senderDeliveryDelayMilliseconds: mixedUnknown && i == 7 ? nil : high ? 2000 : 120))
            }
            f.diagnostics.transport = transport.snapshot
            XCTAssertEqual(try window(f, transport: recoveryLimits).transportPressure, mixedUnknown ? .unknown : .nominal)
        }
        XCTAssertEqual(try window(fixture(rtt: 501, delay: 10000), transport: recoveryLimits).transportPressure, .elevated)
    }

    func testRecentPressureCanReduceBeforeFiveSecondsAfterProfileAcknowledgment() throws {
        var f = try fixture(buffer: 501)
        f.applied.acknowledgedAt = 109
        let w = try XCTUnwrap(local(f, after: 109))
        XCTAssertEqual(w.start, 110.75); XCTAssertEqual(w.end, 111)
        XCTAssertEqual(w.transportPressure, .elevated)
        XCTAssertNil(w.receiver); XCTAssertNil(w.capturedFreshFrames); XCTAssertNil(w.usableVideoCapacity)
    }
    func testRecentPressureDoesNotWaitFiveSecondsAfterLastReceiverWindow() throws {
        let f = try fixture(buffer: 501)
        let w = try XCTUnwrap(local(f, after: 109))
        XCTAssertEqual(w.start, 110.75); XCTAssertEqual(w.end, 111)
        XCTAssertNil(try local(f, after: 110.750001))
    }
    func testLocalPressurePreservesUnknownDeliveryAndOnlyPermitsDecrease() throws {
        let f = try fixture(buffer: 501), w = try XCTUnwrap(local(f))
        XCTAssertEqual(w.start, 110.75); XCTAssertEqual(w.end, 111)
        XCTAssertEqual(w.sequence, 7); XCTAssertEqual(w.appliedRevision, 0)
        XCTAssertEqual(w.attemptID, attempt); XCTAssertEqual(w.transportPressure, .elevated)
        XCTAssertNil(w.capturedFreshFrames); XCTAssertNil(w.encodedFreshFrames)
        XCTAssertNil(w.receiver); XCTAssertNil(w.sourceLoss); XCTAssertNil(w.usableVideoCapacity)
        XCTAssertEqual(w.workerPressure, .unknown); XCTAssertEqual(w.connectivity, .unknown)
        var policy = try QualityController(profiles: [.init(id: "hd", width: 1920, height: 1080,
            minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)], attemptID: attempt,
            applied: f.applied.settings, at: f.applied.acknowledgedAt, recoveryStrategy: .receiverValidatedTrials)
        let decision = try policy.evaluateLocalPressure(w, at: f.now)
        XCTAssertEqual(decision.state, .unknown)
        XCTAssertEqual(decision.recommendation?.kind, .decrease)
        XCTAssertEqual(decision.recommendation?.settings.videoBitrate, 1_600_000)
        XCTAssertTrue(decision.reasons.contains(.missingReceiver))
    }
    func testLocalNominalAndMissingPressureNeverEstablishHealth() throws {
        var f = try fixture()
        XCTAssertNil(try local(f))
        f.diagnostics.thermal = PublishingThermalTracker().snapshot
        f.diagnostics.transport = PublishingTransportStatisticsTracker().snapshot
        XCTAssertNil(try local(f))
        f = try fixture(buffer: 501)
        XCTAssertNil(try Adapter.localPressureWindow(applied: f.applied, diagnostics: f.diagnostics,
            transportLimits: nil, sequence: 7, after: nil, at: f.now))
        for state in [PublishingThermalState.fair, .unknown] {
            XCTAssertNil(try local(fixture(thermalState: state)))
        }
    }
    func testLocalPressureUsesEachKnownCauseAndExactThresholds() throws {
        XCTAssertNil(try local(fixture(retransmitted: 100, buffer: 500, rtt: 500)))
        for f in [try fixture(buffer: 501), try fixture(rtt: 501),
                  try fixture(retransmitted: 101), try fixture(drops: 1)] {
            XCTAssertEqual(try local(f)?.transportPressure, .elevated)
        }
        for state in [PublishingThermalState.serious, .critical] {
            var f = try fixture(thermalState: state)
            f.diagnostics.transport = PublishingTransportStatisticsTracker().snapshot
            XCTAssertEqual(try local(f)?.thermalPressure, .elevated)
        }
        for items in [2, 3] {
            var f = try fixture()
            var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
            ingress.updateOccupancy(items: items, bytes: items, phase: .admitting, at: 100)
            f.diagnostics.ingress = ingress.poll(at: 111)
            let w = try local(f)
            if items == 3 { XCTAssertEqual(w?.meanQueueOccupancy, 0.75) }
            else { XCTAssertNil(w) }
        }
    }
    func testLocalLaggingNominalHistoryCannotSuppressIndependentTransportPressure() throws {
        var f = try fixture(), thermal = PublishingThermalTracker(), transport = PublishingTransportStatisticsTracker()
        for i in 0...5 {
            thermal.observe(.init(state: .nominal, sampledAt: 105.5 + Double(i)))
            transport.observe(.init(publishingGeneration: 7, sampledAt: 106 + Double(i), elapsedMilliseconds: Int64(i * 1000),
                sentBytes: UInt64(i * 1000), retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 10,
                estimatedBandwidthMbps: 999, senderBufferedBytes: 1000, senderBufferMilliseconds: 501, availableSenderBytes: 0))
        }
        f.diagnostics.thermal = thermal.snapshot; f.diagnostics.transport = transport.snapshot
        let w = try XCTUnwrap(local(f))
        XCTAssertEqual(w.start, 110.75); XCTAssertEqual(w.end, 111)
        XCTAssertEqual(w.transportPressure, .elevated); XCTAssertEqual(w.thermalPressure, .unknown)
    }
    func testLocalPressureDuringTrialRequiresBaselineRollback() throws {
        var policy = try QualityController(profiles: [.init(id: "hd", width: 1920, height: 1080,
            minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)], attemptID: attempt,
            applied: .init(profileID: "hd", videoBitrate: 2_000_000), at: 100, recoveryStrategy: .receiverValidatedTrials)
        var recommendation: QualityController.Recommendation?
        for i in 0..<6 {
            let start = 100 + Double(i) * 5
            recommendation = try policy.evaluate(.init(attemptID: attempt, sequence: UInt64(i + 1), appliedRevision: 0,
                start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
                receiver: .init(freshFrames: 150, observedAt: start + 5), sourceLoss: .init(expectedFrames: 150, lostFrames: 0),
                meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal), at: start + 5).recommendation
        }
        let trial = try XCTUnwrap(recommendation)
        XCTAssertEqual(trial.kind, .trial)
        try policy.acknowledge(trial, applied: trial.settings, at: 130)
        let config = VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: trial.settings.videoBitrate)!
        var f = try fixture(buffer: 501, frameOffset: 24 * 30, encodingConfiguration: config)
        f.applied.acknowledgedAt = 130; f.applied.revision = 1
        let w = try XCTUnwrap(local(f, after: 130))
        XCTAssertEqual(w.start, 134.75); XCTAssertEqual(w.end, 135)
        let decision = try policy.evaluateLocalPressure(w, at: f.now)
        XCTAssertEqual(decision.recommendation?.kind, .rollback)
        XCTAssertEqual(decision.recommendation?.settings.videoBitrate, 2_000_000)
    }
    func testLocalPressureRejectsWrongOwnerAndSettings() throws {
        let base = try fixture(buffer: 501)
        var cases: [Fixture] = []
        var f = base; f.applied.attemptID = UUID(); cases.append(f)
        f = base; f.diagnostics.isPublishing = false; cases.append(f)
        f = base; f.diagnostics.clock = nil; cases.append(f)
        f = base; f.diagnostics.clock = .init(sourceOrigin: .zero, publishingGeneration: 8); cases.append(f)
        f = base; f.diagnostics.receipt = nil; cases.append(f)
        f = base; f.diagnostics.ingress = nil; cases.append(f)
        f = base; f.applied.settings = .init(profileID: "hd", videoBitrate: 3_000_000); cases.append(f)
        f = base; f.diagnostics.receipt = .init(publishingGeneration: 7, configuration: config, acceptedAt: 100.01, lastSubmittedSourcePTS: .zero)!; cases.append(f)
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        f = base; f.diagnostics.ingress = ingress.close(at: 111); cases.append(f)
        for value in cases { XCTAssertThrowsError(try local(value)) }
    }
    func testLocalPressureRejectsInvalidTimesAndDoesNotShortenOrOverlap() throws {
        let base = try fixture(buffer: 501)
        for time in [Double.nan, Double.infinity, -1, 1e12 + 1, 100] {
            var f = base; f.now = time; XCTAssertThrowsError(try local(f))
        }
        for ack in [Double.nan, Double.infinity, 99.9, 112] {
            var f = base; f.applied.acknowledgedAt = ack; XCTAssertThrowsError(try local(f))
        }
        for end in [Double.nan, Double.infinity, -1, 112] {
            XCTAssertThrowsError(try local(base, after: end))
        }
        XCTAssertNotNil(try local(base, after: 110))
        XCTAssertNil(try local(base, after: 110.750001))
        var f = base; f.applied.acknowledgedAt = 110
        XCTAssertNotNil(try local(f))
        f.applied.acknowledgedAt = 110.000001
        XCTAssertNil(try local(f))
        f = base; f.now = 113
        XCTAssertNotNil(try local(f))
        f.now = 113.000001
        XCTAssertNil(try local(f))
    }
    func testLocalEndpointUsesActualFreshCollectionsAndExcludesPreAckBrackets() throws {
        var f = try fixture(thermalState: .serious)
        var thermal = PublishingThermalTracker()
        for i in 0...11 { thermal.observe(.init(state: .serious, sampledAt: 99.9 + Double(i))) }
        f.diagnostics.thermal = thermal.snapshot
        let w = try XCTUnwrap(local(f))
        XCTAssertEqual(w.end, 110.9); XCTAssertEqual(w.start, 110.65)
        f.applied.acknowledgedAt = 109.9
        XCTAssertNotNil(try local(f))
        // The current rate starts after the left enclosing sample at 109.
        // Transport pressure must not borrow that pre-ack sample.
        f = try fixture()
        var transport = PublishingTransportStatisticsTracker()
        for i in 0...11 {
            transport.observe(.init(publishingGeneration: 7, sampledAt: 100 + Double(i), elapsedMilliseconds: Int64(i * 1000),
                sentBytes: UInt64(i * 1000), retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 10,
                estimatedBandwidthMbps: 999, senderBufferedBytes: 1000,
                senderBufferMilliseconds: i == 9 ? 501 : 0, availableSenderBytes: 0))
        }
        f.diagnostics.transport = transport.snapshot; f.diagnostics.thermal = thermal.snapshot
        f.applied.acknowledgedAt = 109.9
        XCTAssertEqual(try local(f)?.end, 110.9)
        XCTAssertEqual(try local(f)?.thermalPressure, .elevated)
        XCTAssertEqual(try local(f)?.transportPressure, .nominal)
        f.diagnostics.thermal = PublishingThermalTracker().snapshot
        XCTAssertNil(try local(f)) // The only transport pressure was before acknowledgment.
        f = try fixture(buffer: 501)
        f.diagnostics.thermal = thermal.snapshot; f.applied.acknowledgedAt = 109.9
        XCTAssertEqual(try local(f)?.end, 111) // Prefer the newer independently unhealthy endpoint.
        XCTAssertEqual(try local(f)?.transportPressure, .elevated)
        XCTAssertEqual(try local(f)?.thermalPressure, .unknown)
    }
    func testLocalGappedClosedAndQuarantinedHistoriesCannotTriggerDecrease() throws {
        var f = try fixture()
        for times in [[105.0, 111.0], [110.0, 109.0], [106.0, 107, 108, 109, 110, 111]] {
            var thermal = PublishingThermalTracker()
            for t in times { thermal.observe(.init(state: .critical, sampledAt: t)) }
            if times.count > 2 { thermal.close() }
            f.diagnostics.thermal = thermal.snapshot
            XCTAssertNil(try local(f))
        }
        var transport = PublishingTransportStatisticsTracker()
        for i in [0, 1, 2, 3, 4, 5] {
            transport.observe(.init(publishingGeneration: 8, sampledAt: 106 + Double(i), elapsedMilliseconds: Int64(i * 1000),
                sentBytes: UInt64(i * 1000), retransmittedBytes: 0, droppedPackets: 0, rttMilliseconds: 999,
                estimatedBandwidthMbps: 999, senderBufferedBytes: 0, senderBufferMilliseconds: 999, availableSenderBytes: 0))
        }
        f.diagnostics.transport = transport.snapshot
        XCTAssertNil(try local(f))
        var ingress = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        ingress.updateOccupancy(items: 4, bytes: 100, phase: .admitting, at: 100)
        ingress.updateOccupancy(items: 4, bytes: 100, phase: .draining, at: 109)
        f.diagnostics.ingress = ingress.poll(at: 111)
        XCTAssertNil(try local(f))
    }
    func testBuildsWindowFromMatchedHistoryAndVerifiedReceiptRatherThanFixedScopeRevision() throws {
        let f = try fixture(), w = try window(f)
        XCTAssertEqual(w.appliedRevision, 0); XCTAssertEqual(f.source.interval.scope.appliedProfileRevision, 1)
        XCTAssertEqual(w.attemptID, attempt); XCTAssertEqual(w.sequence, 2)
        XCTAssertEqual(w.start, 100 + 149.0 / 30); XCTAssertEqual(w.end, 100 + 299.0 / 30)
        XCTAssertEqual(w.capturedFreshFrames, 150); XCTAssertEqual(w.encodedFreshFrames, 150)
        XCTAssertEqual(w.receiver?.freshFrames, 150); XCTAssertEqual(w.receiver?.observedAt, 110.75)
        XCTAssertEqual(w.sourceLoss?.expectedFrames, 150); XCTAssertEqual(w.sourceLoss?.lostFrames, 0)
        XCTAssertEqual(w.meanQueueOccupancy, 0.25); XCTAssertNil(w.usableVideoCapacity)
        XCTAssertEqual(w.workerPressure, .nominal); XCTAssertEqual(w.transportPressure, .nominal)
        XCTAssertEqual(w.thermalPressure, .nominal); XCTAssertEqual(w.connectivity, .connected)
    }
    func testRejectsWrongOwnershipConfigurationAndAppliedBoundary() throws {
        let base = try fixture()
        var cases: [Fixture] = []
        var f = base; f.applied.attemptID = UUID(); cases.append(f)
        f = base; f.diagnostics.isPublishing = false; cases.append(f)
        f = base; f.diagnostics.clock = .init(sourceOrigin: .zero, publishingGeneration: 8); cases.append(f)
        f = base; f.diagnostics.receipt = nil; cases.append(f)
        f = base; f.applied.acknowledgedAt = 105; cases.append(f)
        f = base; f.applied.settings = .init(profileID: "hd", videoBitrate: 3_000_000); cases.append(f)
        f = base; f.applied.receipt = .init(publishingGeneration: 7, configuration: config, acceptedAt: 100,
            lastSubmittedSourcePTS: CMTime(value: 150, timescale: 30))!; cases.append(f)
        f = base; f.diagnostics.receipt = .init(publishingGeneration: 7, configuration: config, acceptedAt: 100.01,
            lastSubmittedSourcePTS: .zero)!; cases.append(f)
        for value in cases { XCTAssertThrowsError(try window(value)) }
        let other = VideoEncodingConfiguration(id: UUID(), encoderSessionID: config.encoderSessionID, bitRate: config.bitRate)!
        XCTAssertThrowsError(try window(fixture(configurations: [160: other])))
        XCTAssertThrowsError(try window(fixture(configurations: [160: nil])))
        // The exclusive source anchor may use prior settings; it is excluded from coverage.
        XCTAssertNoThrow(try window(fixture(configurations: [149: other])))
    }
    func testRejectsStaleOrFutureTimesAndPreservesOriginalDecoderAge() throws {
        let base = try fixture()
        for time in [109.0, 112.0, Double.nan, Double.infinity, -1] {
            var f = base; f.now = time; XCTAssertThrowsError(try window(f))
        }
        XCTAssertThrowsError(try window(base, instant: now - .milliseconds(1)))
        XCTAssertThrowsError(try window(base, instant: now + .seconds(2)))
        XCTAssertThrowsError(try window(base, instant: now + .seconds(6)))
        var f = base; f.now = 110
        // Conservative remote age may place its earliest completion before capture end.
        // Causal source identity tightens that lower bound; the age gate still applies.
        XCTAssertEqual(try window(f).receiver?.observedAt, f.source.interval.captureBoundaryEndTime)
    }
    func testUnknownPressureIsExplicitAndCapacityNeverComesFromBandwidth() throws {
        var f = try fixture()
        let unqualified = try Adapter.window(source: f.source, applied: f.applied, diagnostics: f.diagnostics,
            workerLimits: nil, transportLimits: nil, at: f.now, instant: now)
        XCTAssertEqual(unqualified.workerPressure, .unknown); XCTAssertEqual(unqualified.transportPressure, .unknown)
        XCTAssertNil(unqualified.usableVideoCapacity)
        f.source.processing = nil
        f.diagnostics.ingress = nil
        f.diagnostics.thermal = PublishingThermalTracker().snapshot
        f.diagnostics.transport = PublishingTransportStatisticsTracker().snapshot
        let missing = try window(f)
        XCTAssertNil(missing.meanQueueOccupancy)
        XCTAssertEqual(missing.workerPressure, .unknown); XCTAssertEqual(missing.thermalPressure, .unknown)
        XCTAssertEqual(missing.transportPressure, .unknown)
    }
    func testThermalAndTransportClassifyOnlyOpenFreshEnclosingSamples() throws {
        for (state, expected) in [(PublishingThermalState.nominal, QualityController.Pressure.nominal),
            (.fair, .unknown), (.serious, .elevated), (.critical, .elevated), (.unknown, .unknown)] {
            XCTAssertEqual(try window(fixture(thermalState: state)).thermalPressure, expected)
        }
        XCTAssertEqual(try window(fixture(buffer: 500, rtt: 500)).transportPressure, .nominal)
        XCTAssertEqual(try window(fixture(buffer: 501)).transportPressure, .elevated)
        XCTAssertEqual(try window(fixture(rtt: 501)).transportPressure, .elevated)
        XCTAssertEqual(try window(fixture(retransmitted: 100)).transportPressure, .nominal)
        XCTAssertEqual(try window(fixture(retransmitted: 101)).transportPressure, .elevated)
        XCTAssertEqual(try window(fixture(drops: 1)).transportPressure, .elevated)
        var f = try fixture(), thermal = PublishingThermalTracker(), transport = PublishingTransportStatisticsTracker()
        for i in 0...11 { thermal.observe(.init(state: .nominal, sampledAt: 100 + Double(i))) }
        thermal.close(); f.diagnostics.thermal = thermal.snapshot
        transport.close(); f.diagnostics.transport = transport.snapshot
        XCTAssertEqual(try window(f).thermalPressure, .unknown); XCTAssertEqual(try window(f).transportPressure, .unknown)
    }
    func testProcessingPendingOmittedUnknownAndContradictoryEvidence() throws {
        let base = try fixture()
        var f = base; f.source.processing?.interval.pendingFrames = 1
        f.source.processing?.interval.completedFrames = 149; f.source.processing?.interval.processingDuration = nil
        XCTAssertEqual(try window(f).workerPressure, .unknown)
        f = base; f.source.processing?.interval.submittedFrames = 149
        f.source.processing?.interval.completedFrames = 149; f.source.processing?.interval.omittedBeforeEncoderFrames = 1
        XCTAssertEqual(try window(f).workerPressure, .elevated)
        f = base; f.source.processing?.interval.filterDuration = nil
        XCTAssertEqual(try window(f).workerPressure, .unknown)
        f = base; f.source.processing?.interval.filterDuration?.maximumMs = 250
        f.source.processing?.interval.processingDuration?.maximumMs = 1000
        XCTAssertEqual(try window(f).workerPressure, .nominal)
        f.source.processing?.interval.processingDuration?.maximumMs = 1001
        XCTAssertEqual(try window(f).workerPressure, .elevated)
        for mutation in [
            { (p: inout WorkerProcessingReport) in p.encoder = "software" },
            { p in p.scopeID = "bad" }, { p in p.scopeID += "\n" }, { p in p.sequence += 1 },
            { p in p.interval.sourceStartExclusive += 1 }, { p in p.firstPTS += 1 },
            { p in p.interval.decodedFrames += 1 }, { p in p.interval.completedFrames = Int64.max },
            { p in p.interval.pendingFrames = -1 }, { p in p.interval.filterDuration?.maximumMs = .nan }
        ] {
            f = base; mutation(&f.source.processing!)
            XCTAssertEqual(try window(f).workerPressure, .unknown)
        }
    }
    func testCountsBothCaptureAndIngressLossWithoutInventingWorkerOutputLoss() throws {
        let w = try window(fixture(missingEncoded: [200], decodedCount: 145))
        XCTAssertEqual(w.capturedFreshFrames, 150); XCTAssertEqual(w.encodedFreshFrames, 149)
        XCTAssertEqual(w.receiver?.freshFrames, 145)
        XCTAssertEqual(w.sourceLoss?.expectedFrames, 150); XCTAssertEqual(w.sourceLoss?.lostFrames, 5)
    }
    func testRejectsUnqualifiedLimitValues() {
        for x in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(Adapter.WorkerLimits(encoder: "software", maximumFilterMs: x, maximumProcessingMs: 1))
            XCTAssertNil(Adapter.WorkerLimits(encoder: "software", maximumFilterMs: 1, maximumProcessingMs: x))
            XCTAssertNil(Adapter.TransportLimits(maximumBufferMs: x, maximumRTTMs: 1, maximumRetransmittedFraction: 0))
        }
        XCTAssertNil(Adapter.WorkerLimits(encoder: "other", maximumFilterMs: 1, maximumProcessingMs: 1))
        for fraction in [-1.0, 1, .nan, .infinity] {
            XCTAssertNil(Adapter.TransportLimits(maximumBufferMs: 1, maximumRTTMs: 1, maximumRetransmittedFraction: fraction))
        }
    }


    func testMissingBracketsWrongGenerationAndQuarantinedHistoriesStayUnknown() throws {
        func transport(_ times: [Double], generation: UInt64 = 7, sends: Bool = true) -> PublishingTransportStatisticsSnapshot {
            var tracker = PublishingTransportStatisticsTracker()
            for t in times {
                tracker.observe(.init(publishingGeneration: generation, sampledAt: t, elapsedMilliseconds: Int64(t * 1000),
                    sentBytes: sends ? UInt64(t * 10000) : 0, retransmittedBytes: 0, droppedPackets: 0,
                    rttMilliseconds: 10, estimatedBandwidthMbps: 999, senderBufferedBytes: 0,
                    senderBufferMilliseconds: 0, availableSenderBytes: 10000))
            }
            return tracker.snapshot
        }
        var f = try fixture()
        let normal = (100...111).map(Double.init)
        for snapshot in [transport(normal, generation: 8), transport(normal, sends: false),
                         transport([104, 108, 109, 110, 111]), transport(normal + [110]),
                         transport(Array(normal.dropLast(3)))] {
            f.diagnostics.transport = snapshot
            XCTAssertEqual(try window(f).transportPressure, .unknown)
        }
        for times in [[104.0, 108, 109, 110, 111], normal + [110], Array(normal.dropLast(3))] {
            var tracker = PublishingThermalTracker()
            for t in times { tracker.observe(.init(state: .nominal, sampledAt: t)) }
            f.diagnostics.thermal = tracker.snapshot
            XCTAssertEqual(try window(f).thermalPressure, .unknown)
        }
    }
    func testQueueRequiresLiveFreshCoverageAndMatchingScope() throws {
        var f = try fixture()
        for boundary in [109.0, 112] {
            var queue = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
            queue.updateOccupancy(items: 0, bytes: 0, phase: .admitting, at: 100)
            f.diagnostics.ingress = queue.poll(at: boundary)
            XCTAssertNil(try window(f).meanQueueOccupancy)
        }
        var queue = try LiveIngressObservationAccumulator(scope: scope, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        queue.updateOccupancy(items: 0, bytes: 0, phase: .admitting, at: 100)
        f.diagnostics.ingress = queue.close(at: 111)
        XCTAssertNil(try window(f).meanQueueOccupancy)
        let foreign = VideoFrameObservationScope(recordingID: "other", matchID: scope.matchID,
            broadcastGeneration: 1, publishingAttemptID: attempt, appliedProfileRevision: 1)
        var other = try LiveIngressObservationAccumulator(scope: foreign, monotonicAnchor: 100, maxItems: 4, maxBytes: 100)
        other.updateOccupancy(items: 0, bytes: 0, phase: .admitting, at: 100)
        f.diagnostics.ingress = other.poll(at: 111)
        XCTAssertNil(try window(f).meanQueueOccupancy)
    }
    func testExactSourceAndDecoderFreshnessLimits() throws {
        var f = try fixture()
        f.now = f.source.interval.captureBoundaryEndTime + 2
        XCTAssertNoThrow(try window(f, instant: now + .milliseconds(1750)))
        XCTAssertThrowsError(try window(f, instant: now + .milliseconds(1751)))
        f.now += 0.001
        XCTAssertThrowsError(try window(f, instant: now))
    }
    private func owner(_ f: Fixture, _ native: TelemetryNative) throws -> PublishingQualitySession {
        try .init(operations: .init(setBitRate: { rate, _ in native.write(rate) }, stop: { native.stop() }),
            profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 6_000_000)],
            attemptID: attempt, initial: f.applied.settings, uptime: { native.now })
    }
    func testOwnerLocalWindowSharesOrdinalAndNilProbePreservesPendingAdvice() async throws {
        let f = try fixture(buffer: 501), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        try await owner.bootstrap(); native.setNow(f.now)
        let result = try await owner.evaluateLocalPressure(diagnostics: f.diagnostics, transportLimits: transportLimits)
        let advice = try XCTUnwrap(result?.recommendation)
        XCTAssertEqual(advice.kind, .decrease)
        let first = await owner.snapshot
        XCTAssertEqual(first.lastWindow?.sequence, 1); XCTAssertEqual(first.lastWindow?.end, 111)
        let repeated = try await owner.evaluateLocalPressure(diagnostics: f.diagnostics, transportLimits: transportLimits)
        XCTAssertNil(repeated)
        let unchanged = await owner.snapshot
        XCTAssertEqual(unchanged.lastWindow?.sequence, 1)
        try await owner.apply(advice)
        let applied = await owner.snapshot
        XCTAssertEqual(applied.revision, 1); XCTAssertEqual(applied.applied?.videoBitrate, 1_600_000)
        var next = try fixture(frameOffset: 210, windowSequence: 3, encodingConfiguration: XCTUnwrap(applied.receipt).configuration)
        next.diagnostics.receipt = applied.receipt; native.setNow(next.now)
        _ = try await owner.evaluate(source: next.source, diagnostics: next.diagnostics,
            workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
        let resumed = await owner.snapshot
        XCTAssertEqual(resumed.lastWindow?.sequence, 2); XCTAssertEqual(resumed.lastWindow?.capturedFreshFrames, 150)
        await owner.stop()
    }
    func testOwnerLocalRejectionRevokesAdviceAndMinimumPressureStillAdvances() async throws {
        for rate in [1_000_000, 2_000_000] {
            let config = VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!
            var f = try fixture(buffer: 501, encodingConfiguration: config)
            let native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
            try await owner.bootstrap(); native.setNow(f.now)
            let decision = try await owner.evaluateLocalPressure(diagnostics: f.diagnostics, transportLimits: transportLimits)
            let state = await owner.snapshot
            XCTAssertEqual(state.lastWindow?.sequence, 1)
            if rate == 1_000_000 { XCTAssertNil(decision?.recommendation); XCTAssertEqual(native.calls, 1) }
            else {
                let pending = try XCTUnwrap(decision?.recommendation)
                f.diagnostics.receipt = nil
                do { _ = try await owner.evaluateLocalPressure(diagnostics: f.diagnostics, transportLimits: transportLimits); XCTFail("Missing receipt") } catch {}
                do { try await owner.apply(pending); XCTFail("Invalidated advice") } catch {}
                XCTAssertEqual(native.calls, 1)
            }
            await owner.stop()
        }
    }
    func testOwnerLocalPressureAndRejectionMakeTrialRollbackSticky() async throws {
        for rejected in [false, true] {
            let f = try fixture(), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
            try await owner.bootstrap()
            var advice: QualityController.Recommendation?
            for i in 0..<6 {
                let start = 101 + Double(i) * 5; native.setNow(start + 5)
                advice = try await owner.evaluate(.init(attemptID: attempt, sequence: UInt64(i + 1), appliedRevision: 0,
                    start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
                    receiver: .init(freshFrames: 150, observedAt: start + 5), sourceLoss: .init(expectedFrames: 150, lostFrames: 0),
                    meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                    thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)).recommendation
            }
            try await owner.apply(XCTUnwrap(advice))
            let state = await owner.snapshot
            var local = try fixture(buffer: 501, frameOffset: 26 * 30, encodingConfiguration: XCTUnwrap(state.receipt).configuration)
            local.diagnostics.receipt = rejected ? nil : state.receipt; native.setNow(local.now)
            if rejected {
                do { _ = try await owner.evaluateLocalPressure(diagnostics: local.diagnostics, transportLimits: transportLimits); XCTFail("Missing receipt") } catch {}
            } else {
                let bad = try await owner.evaluateLocalPressure(diagnostics: local.diagnostics, transportLimits: transportLimits)
                XCTAssertEqual(bad?.recommendation?.kind, .rollback)
            }
            let rollback = try await owner.checkTrialDeadline()
            XCTAssertEqual(rollback?.kind, .rollback)
            try await owner.apply(XCTUnwrap(rollback))
            let restored = await owner.snapshot
            XCTAssertEqual(restored.applied?.videoBitrate, 2_000_000); XCTAssertEqual(restored.revision, 2)
            await owner.stop()
        }
    }
    @MainActor func testDriverLocalFallbackForMissingTransitionPendingAndRejectedSource() async throws {
        for kind in ["missing", "transition", "pending", "rejected"] {
            var f = try fixture(configurations: kind == "transition" ? [160: nil] : [:], buffer: 501,
                receivedAt: kind == "rejected" ? .now - .seconds(3) : .now)
            if kind == "pending", let p = f.source.processing {
                f.source.processing = .init(scopeID: p.scopeID, encoder: p.encoder, previousSequence: p.previousSequence,
                    sequence: p.sequence, firstPTS: p.firstPTS,
                    interval: .init(sourceStartExclusive: p.interval.sourceStartExclusive, sourceEndInclusive: p.interval.sourceEndInclusive,
                        decodedFrames: 150, submittedFrames: 150, completedFrames: 149, pendingFrames: 1, omittedBeforeEncoderFrames: 0,
                        filterDuration: p.interval.filterDuration, processingDuration: nil))
            }
            let native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
            var exported: Data?
            let driver = PublishingQualityDriver(owner: owner, workerLimits: workerLimits, transportLimits: transportLimits,
                uptime: { native.now }, export: { exported = $0 })
            await driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)?.value
            native.setNow(f.now)
            await driver.tick(encoderReady: true, source: kind == "missing" ? nil : f.source, diagnostics: f.diagnostics)?.value
            let state = await owner.snapshot
            XCTAssertEqual(state.revision, 1, kind); XCTAssertEqual(state.applied?.videoBitrate, 1_600_000, kind)
            await driver.stop()
            let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
            let events = try XCTUnwrap(trace["events"] as? [[String: Any]])
            let local = try XCTUnwrap(events.first { $0["kind"] as? String == "localPressure" })
            XCTAssertNil(local["source"])
            let window = try XCTUnwrap(local["window"] as? [String: Any])
            XCTAssertTrue(window["received"] is NSNull); XCTAssertEqual(window["connectivity"] as? String, "unknown")
            XCTAssertNotNil(local["evidence"])
        }
    }
    @MainActor func testDriverSourcePriorityDuplicateFallbackAndOverlapSkipping() async throws {
        let f = try fixture(receivedAt: .now), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        let driver = PublishingQualityDriver(owner: owner, workerLimits: workerLimits, transportLimits: transportLimits, uptime: { native.now })
        await driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)?.value
        native.setNow(f.now)
        await driver.tick(encoderReady: true, source: f.source, diagnostics: f.diagnostics)?.value
        var state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.capturedFreshFrames, 150); XCTAssertEqual(native.calls, 1)
        var pressured = try fixture(buffer: 501, frameOffset: 150, windowSequence: 3, receivedAt: .now)
        native.setNow(pressured.now)
        // Duplicate source cannot conceal newer local pressure.
        await driver.tick(encoderReady: true, source: f.source, diagnostics: pressured.diagnostics)?.value
        state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 2); XCTAssertNil(state.lastWindow?.capturedFreshFrames)
        XCTAssertEqual(state.revision, 1); XCTAssertEqual(native.calls, 2)
        pressured.diagnostics.receipt = state.receipt
        await driver.tick(encoderReady: true, source: pressured.source, diagnostics: pressured.diagnostics)?.value
        state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 2); XCTAssertEqual(native.calls, 2)
        var resumed = try fixture(frameOffset: 360, windowSequence: 4, encodingConfiguration: XCTUnwrap(state.receipt).configuration, receivedAt: .now)
        resumed.diagnostics.receipt = state.receipt; native.setNow(resumed.now)
        await driver.tick(encoderReady: true, source: resumed.source, diagnostics: resumed.diagnostics)?.value
        state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 3); XCTAssertEqual(state.lastWindow?.capturedFreshFrames, 150)
        await driver.stop()
    }
    @MainActor func testDriverMinimumPressureSkipsOverlappingSourceWithoutChangingReceipt() async throws {
        let config = VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: 1_000_000)!
        let f = try fixture(buffer: 501, encodingConfiguration: config, receivedAt: .now)
        let native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        let driver = PublishingQualityDriver(owner: owner, workerLimits: workerLimits, transportLimits: transportLimits, uptime: { native.now })
        await driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)?.value
        native.setNow(f.now)
        await driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)?.value
        var state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 1); XCTAssertEqual(state.lastWindow?.end, 111)
        XCTAssertEqual(state.revision, 0); XCTAssertEqual(native.calls, 1)
        let overlap = try fixture(frameOffset: 150, windowSequence: 3, encodingConfiguration: config, receivedAt: .now)
        native.setNow(overlap.now)
        await driver.tick(encoderReady: true, source: overlap.source, diagnostics: overlap.diagnostics)?.value
        state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 1); XCTAssertNil(state.lastWindow?.capturedFreshFrames)
        let resumed = try fixture(frameOffset: 300, windowSequence: 4, encodingConfiguration: config, receivedAt: .now)
        native.setNow(resumed.now)
        await driver.tick(encoderReady: true, source: resumed.source, diagnostics: resumed.diagnostics)?.value
        state = await owner.snapshot
        XCTAssertEqual(state.lastWindow?.sequence, 2); XCTAssertEqual(state.lastWindow?.capturedFreshFrames, 150)
        XCTAssertEqual(state.revision, 0); XCTAssertEqual(native.calls, 1)
        await driver.stop()
    }
    @MainActor func testDriverLocalRejectionsAreBoundedAndStopPreventsQueuedFallbackWrite() async throws {
        let f = try fixture(buffer: 501), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: workerLimits, transportLimits: transportLimits,
            uptime: { native.now }, export: { exported = $0 })
        await driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)?.value
        native.setNow(f.now)
        var invalid = f.diagnostics; invalid.receipt = nil
        for _ in 0..<20 { await driver.tick(encoderReady: true, source: nil, diagnostics: invalid)?.value }
        _ = driver.tick(encoderReady: true, source: nil, diagnostics: f.diagnostics)
        await driver.stop()
        XCTAssertEqual(native.calls, 1)
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        let events = try XCTUnwrap(trace["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["kind"] as? String == "rejected" }.count, 1)
        XCTAssertEqual(events.last?["kind"] as? String, "stopped")
    }
    func testOwnerUsesActualAcknowledgmentAndBoundWindowWithoutChangingSettings() async throws {
        let f = try fixture(), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        try await owner.bootstrap()
        let state = await owner.snapshot
        XCTAssertEqual(state.acknowledgedAt, 100.1)
        XCTAssertEqual(state.receipt?.acceptedAt, 100)
        native.setNow(f.now)
        let decision = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
            workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
        XCTAssertEqual(decision.state, .unknown); XCTAssertTrue(decision.reasons.contains(.missingCapacity))
        XCTAssertNil(decision.recommendation); XCTAssertEqual(native.calls, 1)
        await owner.stop()
    }

    func testWorkerRestartCannotReusePolicySequenceOrAccumulatePreRestartRecovery() async throws {
        let first = try fixture(), native = TelemetryNative(receipt: first.applied.receipt), owner = try owner(first, native)
        try await owner.bootstrap()
        for index in 0..<6 {
            // Independent restarted worker scopes can legitimately repeat decoder sequence 2.
            let epoch = String(format: "%08d-2222-2222-2222-222222222222", index)
            let f = try fixture(frameOffset: index * 150, workerEpoch: epoch)
            native.setNow(f.now)
            let decision = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
            XCTAssertNil(decision.recommendation, "Different workers must not build one 30-second recovery history")
        }
        XCTAssertEqual(native.calls, 1)
        await owner.stop()
    }

    func testMatchedTelemetryQualifiesTrialThenWorkerChangeRequiresRollback() async throws {
        let first = try fixture(), native = TelemetryNative(receipt: first.applied.receipt), owner = try owner(first, native)
        try await owner.bootstrap()
        var advice: QualityController.Recommendation?
        for i in 0..<6 {
            let f = try fixture(frameOffset: i * 150, windowSequence: Int64(i + 2))
            native.setNow(f.now)
            advice = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                workerLimits: workerLimits, transportLimits: transportLimits, instant: now).recommendation
        }
        XCTAssertEqual(advice?.kind, .trial)
        try await owner.apply(XCTUnwrap(advice))
        let applied = await owner.snapshot
        XCTAssertEqual(applied.revision, 1)
        let receipt = try XCTUnwrap(applied.receipt)
        var f = try fixture(frameOffset: 1050, workerEpoch: "99999999-2222-2222-2222-222222222222",
            encodingConfiguration: receipt.configuration)
        f.diagnostics.receipt = receipt
        native.setNow(f.now)
        let decision = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
            workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
        XCTAssertEqual(decision.recommendation?.kind, .rollback)
        XCTAssertEqual(decision.recommendation?.settings.videoBitrate, 2_000_000)
        XCTAssertEqual(native.calls, 2, "Telemetry cannot apply its own advice")
        await owner.stop()
    }

    func testClockSamplingCannotFreshenEvidenceWhileUptimeReadIsDelayed() async throws {
        let f = try fixture(), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        try await owner.bootstrap()
        native.setNow(f.now); native.setReadDelay(2.1)
        do {
            _ = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                workerLimits: workerLimits, transportLimits: transportLimits)
            XCTFail("Elapsed time inside clock sampling must count toward decoder age")
        } catch { XCTAssertEqual(error as? Adapter.Failure, .freshness) }
        await owner.stop()
    }
    func testDuplicateSourceCannotIssueANewPolicyOrdinalOrKeepAdvice() async throws {
        let f = try fixture(decodedCount: 100), native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
        try await owner.bootstrap(); native.setNow(f.now)
        let advice = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
            workerLimits: workerLimits, transportLimits: transportLimits, instant: now).recommendation
        do {
            _ = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
            XCTFail("Duplicate source interval must be rejected")
        } catch { XCTAssertEqual(error as? QualityController.ValidationError, .outOfOrder) }
        do { try await owner.apply(XCTUnwrap(advice)); XCTFail("Duplicate input revokes stale advice") } catch {}
        XCTAssertEqual(native.calls, 1)
        await owner.stop()
    }
    func testRejectedBoundTelemetryRevokesPriorAdviceAndForcesTrialRollback() async throws {
        for trial in [false, true] {
            var f = try fixture(decodedCount: 100)
            let native = TelemetryNative(receipt: f.applied.receipt), owner = try owner(f, native)
            try await owner.bootstrap()
            var advice: QualityController.Recommendation?
            if trial {
                for i in 0..<6 {
                    let start = 101 + Double(i) * 5
                    native.setNow(start + 5)
                    advice = try await owner.evaluate(.init(attemptID: attempt, sequence: UInt64(i + 1), appliedRevision: 0,
                        start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
                        receiver: .init(freshFrames: 150, observedAt: start + 5), sourceLoss: .init(expectedFrames: 150, lostFrames: 0),
                        meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                        thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal)).recommendation
                }
                XCTAssertEqual(advice?.kind, .trial)
                try await owner.apply(XCTUnwrap(advice))
            } else {
                native.setNow(f.now)
                advice = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                    workerLimits: workerLimits, transportLimits: transportLimits, instant: now).recommendation
                XCTAssertEqual(advice?.kind, .decrease)
            }
            f.diagnostics.receipt = nil
            do {
                _ = try await owner.evaluate(source: f.source, diagnostics: f.diagnostics,
                    workerLimits: workerLimits, transportLimits: transportLimits, instant: now)
                XCTFail("Missing actual receipt must reject telemetry")
            } catch {}
            if trial {
                let rollback = try await owner.checkTrialDeadline()
                XCTAssertEqual(rollback?.kind, .rollback)
            } else {
                do { try await owner.apply(XCTUnwrap(advice)); XCTFail("Rejected telemetry must revoke advice") } catch {}
            }
            XCTAssertEqual(native.calls, trial ? 2 : 1)
            await owner.stop()
        }
    }

}


private final class TelemetryNative: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0, count = 0
    private var delay = 0.0
    private let initial: PublishingBitRateChange
    init(receipt: PublishingBitRateChange) { initial = receipt }
    var now: Double {
        let values = lock.withLock { (time, delay) }
        if values.1 > 0 { Thread.sleep(forTimeInterval: values.1) }
        return values.0
    }
    func setReadDelay(_ value: Double) { lock.withLock { delay = value } }
    var calls: Int { lock.withLock { count } }
    func setNow(_ value: Double) { lock.withLock { time = value } }
    func write(_ rate: Int) -> PublishingBitRateChange {
        lock.withLock {
            count += 1
            let accepted = time; time += 0.1
            let config = count == 1 ? initial.configuration : VideoEncodingConfiguration(id: UUID(), encoderSessionID: initial.configuration.encoderSessionID, bitRate: rate)!
            return PublishingBitRateChange(publishingGeneration: initial.publishingGeneration, configuration: config,
                acceptedAt: accepted, lastSubmittedSourcePTS: initial.lastSubmittedSourcePTS)!
        }
    }
    func stop() {}
}
