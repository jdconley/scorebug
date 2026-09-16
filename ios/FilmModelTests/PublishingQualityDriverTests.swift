import CoreMedia
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class PublishingQualityDriverTests: XCTestCase {
    func testTransportEvidenceKeepsNegotiatedDelayOnItsActualSampleAndPreservesUnknown() throws {
        var history = PublishingTransportStatisticsTracker()
        for (time, delay) in [(10.0, nil as Int32?), (10.25, 120), (10.5, 0)] {
            history.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
                sentBytes: UInt64(time * 1000), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: 100, senderBufferedBytes: 1,
                senderBufferMilliseconds: 1, availableSenderBytes: 1000, senderDeliveryDelayMilliseconds: delay))
        }
        let evidence = PublishingQualityDriver.transportEvidence(history.snapshot)
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples[0]["senderDeliveryDelayMilliseconds"] is NSNull)
        XCTAssertEqual(samples[1]["senderDeliveryDelayMilliseconds"] as? Int32, 120)
        XCTAssertEqual(samples[1]["sampledAt"] as? Double, 10.25)
        XCTAssertEqual(samples[2]["senderDeliveryDelayMilliseconds"] as? Int32, 0)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence))
    }

    func testTransportEvidenceExportsActualPacingAndPreservesUnknown() throws {
        var history = PublishingTransportStatisticsTracker()
        for (time, maximum, period) in [(10.0, nil as Double?, nil as Double?), (10.25, 7.5, 1403.7)] {
            history.observe(.init(publishingGeneration: 7, sampledAt: time, elapsedMilliseconds: Int64(time * 1000),
                sentBytes: UInt64(time * 1000), retransmittedBytes: 0, droppedPackets: 0,
                rttMilliseconds: 1, estimatedBandwidthMbps: 100, senderBufferedBytes: 1,
                senderBufferMilliseconds: 1, availableSenderBytes: 1000,
                senderMaximumBandwidthMbps: maximum, packetSendPeriodMicroseconds: period))
        }
        let evidence = PublishingQualityDriver.transportEvidence(history.snapshot)
        let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
        XCTAssertTrue(samples[0]["senderMaximumBandwidthMbps"] is NSNull)
        XCTAssertTrue(samples[0]["packetSendPeriodMicroseconds"] is NSNull)
        XCTAssertEqual(samples[1]["senderMaximumBandwidthMbps"] as? Double, 7.5)
        XCTAssertEqual(samples[1]["packetSendPeriodMicroseconds"] as? Double, 1403.7)
        XCTAssertEqual(samples[1]["sampledAt"] as? Double, 10.25)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence))
    }

    private func make(_ native: DriverNative) throws -> (PublishingQualityDriver, PublishingQualityTelemetry.Diagnostics) {
        let owner = try PublishingQualitySession(operations: native.operations,
            profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
            attemptID: UUID(), initial: .init(profileID: "hd", videoBitrate: 6_000_000), uptime: { 100 })
        let diagnostics = PublishingQualityTelemetry.Diagnostics(isPublishing: true, clock: nil, receipt: nil, ingress: nil,
            transport: PublishingTransportStatisticsTracker().snapshot, thermal: PublishingThermalTracker().snapshot)
        return (.init(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { 100 }), diagnostics)
    }
    func testExpiredAdviceSkipsWriteAndLaterAdviceStillApplies() async throws {
        let native = DriverNative(), attempt = UUID()
        native.release()
        let owner = try PublishingQualitySession(operations: native.operations,
            profiles: [.init(id: "hd", width: 1920, height: 1080, minimumBitrate: 1_000_000, maximumBitrate: 12_000_000)],
            attemptID: attempt, initial: .init(profileID: "hd", videoBitrate: 6_000_000), uptime: { native.now })
        var exported: Data?
        let driver = PublishingQualityDriver(owner: owner, workerLimits: nil, transportLimits: nil, uptime: { native.now },
                                             export: { exported = $0 })
        try await owner.bootstrap()
        func advice(_ start: Double) async throws -> QualityController.Recommendation {
            native.setNow(start + 5)
            let result = try await owner.evaluate(.init(attemptID: attempt, sequence: UInt64(start), appliedRevision: 0,
                start: start, end: start + 5, capturedFreshFrames: 150, encodedFreshFrames: 150,
                receiver: .init(freshFrames: 100, observedAt: start + 5), sourceLoss: .init(expectedFrames: 150, lostFrames: 50),
                meanQueueOccupancy: 0, usableVideoCapacity: nil, connectivity: .connected,
                thermalPressure: .nominal, workerPressure: .nominal, transportPressure: .nominal))
            return try XCTUnwrap(result.recommendation)
        }
        let expired = try await advice(100)
        native.setNow(expired.validUntil + 0.1)
        try await driver.apply(expired)
        XCTAssertFalse(driver.isClosed); XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 0)
        let fresh = try await advice(105)
        try await driver.apply(fresh)
        XCTAssertEqual(native.calls, 2)
        let snapshot = await owner.snapshot
        XCTAssertFalse(snapshot.isClosed); XCTAssertEqual(snapshot.revision, 1)
        await driver.stop()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(exported)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 4)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let applied = try XCTUnwrap(events.first { $0["kind"] as? String == "applied" })
        let application = try XCTUnwrap(applied["application"] as? [String: Any])
        XCTAssertEqual(application["admittedAt"] as? Double, 110)
        XCTAssertEqual(application["completionDeadline"] as? Double, 112)
        XCTAssertEqual(application["attemptID"] as? String, attempt.uuidString)
        XCTAssertEqual(application["fromRevision"] as? String, "0")
        XCTAssertEqual(application["windowSequence"] as? String, "105")
        XCTAssertEqual(application["id"] as? String, snapshot.application?.id.uuidString)
    }
    func testWaitsForEncoderAndCoalescesHealthTicksIntoOneBootstrap() async throws {
        let native = DriverNative(), (driver, diagnostics) = try make(native)
        driver.tick(encoderReady: false, source: nil, diagnostics: diagnostics)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(native.calls, 0)
        for _ in 0..<100 { driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics) }
        let end = ContinuousClock.now + .seconds(2)
        while native.calls == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(native.calls, 1)
        native.release()
        while driver.bootstrapCount == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(driver.bootstrapCount, 1)
        await driver.stop()
    }
    func testStopJoinsSuspendedWriteAndPreventsLateBootstrapOrFutureTicks() async throws {
        let native = DriverNative(), (driver, diagnostics) = try make(native)
        driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        let end = ContinuousClock.now + .seconds(2)
        while native.calls == 0, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(native.calls, 1)
        await driver.stop()
        XCTAssertTrue(driver.isClosed); XCTAssertEqual(driver.bootstrapCount, 0)
        driver.tick(encoderReady: true, source: nil, diagnostics: diagnostics)
        await driver.stop()
        XCTAssertEqual(native.calls, 1); XCTAssertEqual(native.stops, 1)
    }
}
private final class DriverNative: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, stopCount = 0
    private var clock = 100.0
    var now: Double { lock.withLock { clock } }
    func setNow(_ value: Double) { lock.withLock { clock = value } }
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var calls: Int { lock.withLock { count } }
    var stops: Int { lock.withLock { stopCount } }
    var operations: PublishingQualitySession.Operations {
        .init(setBitRate: { rate, _ in
            self.lock.withLock { self.count += 1 }
            await withCheckedContinuation { c in
                let ready = self.lock.withLock { if self.released { return true }; self.continuation = c; return false }
                if ready { c.resume() }
            }
            return PublishingBitRateChange(publishingGeneration: 1,
                configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
                acceptedAt: self.now, lastSubmittedSourcePTS: nil)!
        }, stop: { self.lock.withLock { self.stopCount += 1 }; self.release() })
    }
    func release() {
        let c = lock.withLock { released = true; let c = continuation; continuation = nil; return c }
        c?.resume()
    }
}
