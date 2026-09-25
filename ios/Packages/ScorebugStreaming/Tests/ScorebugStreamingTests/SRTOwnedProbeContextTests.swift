import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming
@testable import HaishinKit
@testable import SRTHaishinKit

final class SRTOwnedProbeContextTests: XCTestCase {
    func testNativeReceiptRequiresEveryExactSelectorField() {
        let context = PublishingBandwidthProbeContext(issuer: UUID(), epoch: UUID(), selected: contextReceipt())
        for field in ["", "generation", "configuration", "encoder", "bitrate", "accepted", "pts", "absentPTS", "timescale"] {
            let receipt = contextReceipt(changing: field)
            let native = SRTStream.VideoBitRateReceipt(publishingGeneration: receipt.publishingGeneration,
                change: .init(settings: .init(bitRate: receipt.configuration.bitRate),
                    configuration: .init(id: receipt.configuration.id, encoderSessionID: receipt.configuration.encoderSessionID,
                        bitRate: receipt.configuration.bitRate), acceptedAt: receipt.acceptedAt,
                    lastSubmittedSourcePTS: receipt.lastSubmittedSourcePTS))
            XCTAssertEqual(context.matches(native), field.isEmpty, field)
        }
    }
    func testExactSelectorFieldsAndRepeatedCaptures() async throws {
        let fixture = ContextFixture(), selected = contextReceipt()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        for field in ["generation", "configuration", "encoder", "bitrate", "accepted", "pts", "absentPTS", "timescale"] {
            await fails(.obsolete) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt(changing: field)) }
        }
        let first = try await publisher.captureOwnedProbeContext(matching: selected)
        let second = try await publisher.captureOwnedProbeContext(matching: selected)
        try await publisher.validateOwnedProbeContext(first)
        try await publisher.validateOwnedProbeContext(second)
        let counts = await fixture.counts
        XCTAssertEqual(counts.writes, 0, "Context reads must not write settings")
        XCTAssertEqual(counts.probes, 0, "Context capture must not allocate probes")
        await publisher.stop()
    }

    func testDisabledCapabilitiesNeverMintAContext() async throws {
        for missingCapture in [false, true] {
            let fixture = ContextFixture()
            var operations = await fixture.operations()
            if missingCapture { operations.captureProbeContext = nil }
            else { operations.validateProbeContext = nil }
            let publisher = SRTMediaPublisher(operations: operations)
            try await publisher.start()
            await fails(.disabled) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
            await fails(.busy) { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000) }
            await publisher.stop()
        }
    }

    func testForeignContextAndImplicitLowerInvalidationFailClosed() async throws {
        let fixture = ContextFixture(), otherFixture = ContextFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        let other = SRTMediaPublisher(operations: await otherFixture.operations())
        try await publisher.start(); try await other.start()
        let context = try await publisher.captureOwnedProbeContext(matching: contextReceipt())
        _ = try await other.captureOwnedProbeContext(matching: contextReceipt())
        await fails(.obsolete) { try await other.validateOwnedProbeContext(context) }
        await fixture.invalidate()
        await fails(.obsolete) { try await publisher.validateOwnedProbeContext(context) }
        await fails(.obsolete) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
        await publisher.stop(); await other.stop()
    }

    func testMutationAttemptsRetireOldContextsAndFreshWriteCanRebind() async throws {
        for cancelled in [false, true] {
            let fixture = ContextFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let old = try await publisher.captureOwnedProbeContext(matching: contextReceipt())
            if cancelled {
                let attempted = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await publisher.setVideoBitRate(800_000)
                }
                if case .success = await attempted.result { XCTFail("Cancelled mutation succeeded") }
                try await publisher.validateOwnedProbeContext(old)
            } else {
                await fixture.rejectWrites()
                do { _ = try await publisher.setVideoBitRate(800_000); XCTFail() } catch {}
                await fails(.obsolete) { try await publisher.validateOwnedProbeContext(old) }
            }
            await fixture.allowWrites()
            let selected = try await publisher.setVideoBitRate(800_000)
            let fresh = try await publisher.captureOwnedProbeContext(matching: selected)
            try await publisher.validateOwnedProbeContext(fresh)
            await fails(.obsolete) { try await publisher.validateOwnedProbeContext(old) }
            await publisher.stop()
        }
    }

    func testProfileMustBeFollowedByVerifiedWrite() async throws {
        let fixture = ContextFixture()
        let active = SRTMediaPublisher(operations: await fixture.operations())
        try await active.start()
        let old = try await active.captureOwnedProbeContext(matching: contextReceipt())
        _ = try await active.setVideoProfile(.sd540)
        await fails(.obsolete) { try await active.validateOwnedProbeContext(old) }
        await fails(.obsolete) { _ = try await active.captureOwnedProbeContext(matching: contextReceipt()) }
        let selected = try await active.setVideoBitRate(800_000)
        let fresh = try await active.captureOwnedProbeContext(matching: selected)
        try await active.validateOwnedProbeContext(fresh)
        await active.stop()
    }

    func testHeldContextReadCannotCrossMutationOrStop() async throws {
        for validating in [false, true] {
            for stopping in [false, true] {
              for heldHealth in [false, true] {
                let fixture = ContextFixture()
                let publisher = SRTMediaPublisher(operations: await fixture.operations())
                try await publisher.start()
                let context = try await publisher.captureOwnedProbeContext(matching: contextReceipt())
                await fixture.hold(heldHealth ? .health : (validating ? .validate : .capture))
                let pending = Task {
                    if validating { try await publisher.validateOwnedProbeContext(context) }
                    else { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
                }
                await fixture.waitForEntry()
                if stopping { await publisher.stop() }
                else { _ = try await publisher.setVideoBitRate(800_000) }
                await fixture.release()
                if case .success = await pending.result { XCTFail("Obsolete context survived an actor suspension") }
                await publisher.stop()
              }
            }
        }
    }

    func testCancelledAdmittedWriteCannotLeaveAnOldContextValid() async throws {
        let fixture = ContextFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let old = try await publisher.captureOwnedProbeContext(matching: contextReceipt())
        await fixture.hold(.write)
        let mutation = Task { try await publisher.setVideoBitRate(800_000) }
        await fixture.waitForEntry()
        mutation.cancel()
        await fails(.obsolete) { try await publisher.validateOwnedProbeContext(old) }
        await fixture.release()
        if case .success = await mutation.result { XCTFail("Cancelled native write survived") }
        await fails(.notPublishing) { try await publisher.validateOwnedProbeContext(old) }
        await publisher.stop()
    }

    func testCaptureReservesExclusiveModeBeforeAwaitAndCancelIsInert() async throws {
        let fixture = ContextFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        await fixture.hold(.capture)
        let capture = Task { try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
        await fixture.waitForEntry()
        let id = UUID()
        await fails(.busy) { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000) }
        await fails(.busy) { _ = try await publisher.renewBandwidthProbe(id: id, publishingGeneration: 7) }
        await fails(.busy) { _ = try await publisher.replaceBandwidthProbe(id: id, publishingGeneration: 7, stage: 1, bitRate: 500_000) }
        await fails(.busy) { _ = try await publisher.restartBandwidthProbe(id: id, publishingGeneration: 7, stage: 1, bitRate: 500_000) }
        await fails(.busy) { try await publisher.retireBandwidthProbe(id: id, publishingGeneration: 7) }
        await publisher.cancelBandwidthProbe(id: id, publishingGeneration: 7)
        await fixture.release()
        let context = try await capture.value
        try await publisher.validateOwnedProbeContext(context)
        let counts = await fixture.counts
        XCTAssertEqual(counts.probes, 0); XCTAssertEqual(counts.cancels, 0)
        await publisher.stop()
    }

    func testLegacyAllocationEvenAfterCancelPreventsOwnedOptIn() async throws {
        let fixture = ContextFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let probe = try await publisher.beginBandwidthProbe(bitRate: 500_000)
        await publisher.cancelBandwidthProbe(id: probe.id, publishingGeneration: 7)
        await fails(.busy) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
        await publisher.stop()
    }

    func testNativeAdapterRejectsContextWithoutActivePublication() async throws {
        let publisher = SRTPublisher()
        await fails(.notPublishing) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
        await publisher.stop()
        await fails(.notPublishing) { _ = try await publisher.captureOwnedProbeContext(matching: contextReceipt()) }
    }

    private func fails(_ expected: PublishingBandwidthProbeError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, expected) }
    }
}

private func contextReceipt(changing field: String = "") -> PublishingBitRateChange {
    let configuration = VideoEncodingConfiguration(
        id: UUID(uuidString: field == "configuration" ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000001")!,
        encoderSessionID: UUID(uuidString: field == "encoder" ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000002")!,
        bitRate: field == "bitrate" ? 800_000 : 900_000)!
    return PublishingBitRateChange(publishingGeneration: field == "generation" ? 8 : 7, configuration: configuration,
        acceptedAt: field == "accepted" ? 11 : 10,
        lastSubmittedSourcePTS: field == "absentPTS" ? nil : CMTime(value: field == "pts" ? 31 : (field == "timescale" ? 60 : 30), timescale: field == "timescale" ? 60 : 30))!
}

private actor ContextFixture {
    enum Hold { case capture, validate, health, write }
    let issuer = UUID(), epoch = UUID()
    var current: PublishingBitRateChange? = contextReceipt()
    var counts = (writes: 0, probes: 0, cancels: 0)
    private var rejectedWrites = false
    private var held: Hold?, entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold(_ value: Hold) { held = value; entered = false }
    func release() { held = nil; continuation?.resume(); continuation = nil }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    func pause(_ value: Hold) async {
        guard held == value else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func invalidate() { current = nil }
    func rejectWrites() { rejectedWrites = true }
    func allowWrites() { rejectedWrites = false }
    func capture(_ selected: PublishingBitRateChange) async throws -> PublishingBandwidthProbeContext {
        // Deliberately return the lower's actual selector even for mismatched input:
        // the upper adapter must verify it instead of trusting a generic success.
        guard let current else { throw PublishingBandwidthProbeError.obsolete }
        let result = PublishingBandwidthProbeContext(issuer: issuer, epoch: epoch, selected: current)
        await pause(.capture)
        return result
    }
    func validate(_ context: PublishingBandwidthProbeContext) async throws {
        guard let current, context.issuer == issuer, context.matches(current) else { throw PublishingBandwidthProbeError.obsolete }
        await pause(.validate)
    }
    func healthy() async -> Bool { await pause(.health); return true }
    func write(_ value: Int) async throws -> PublishingBitRateChange {
        counts.writes += 1
        await pause(.write)
        guard !rejectedWrites else { throw PublishingBandwidthProbeError.failed }
        current = contextReceipt(changing: value == 800_000 ? "bitrate" : "")
        return current!
    }
    func profile(_ value: PublishingVideoProfile) -> PublishingVideoProfileChange {
        current = nil
        return PublishingVideoProfileChange(profile: value, publishingGeneration: 7,
            previousEncoderSessionID: UUID(), encoderSessionID: UUID(), lastOldSourcePTS: .zero,
            firstNewSourcePTS: CMTime(value: 1, timescale: 30), width: value.width, height: value.height,
            rawVideoFramesDropped: 0, acknowledgedAt: 12)!
    }
    func begin(_ value: Int) -> PublishingBandwidthProbeSnapshot {
        counts.probes += 1
        return .init(id: UUID(), publishingGeneration: 7, bitRate: value, startedAt: 10,
            leaseDeadline: 11, acceptedPayloadBytes: 0, lastAcceptedAt: nil, reason: nil)
    }
    func cancel() { counts.cancels += 1 }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: {}, start: {}, append: { _ in }, isPublishing: { await self.healthy() }, stop: {},
            setBitRate: { try await self.write($0) }, metrics: { nil },
            setProfile: { await self.profile($0) }, beginProbe: { await self.begin($0) },
            cancelProbe: { _, _ in await self.cancel() },
            captureProbeContext: { try await self.capture($0) },
            validateProbeContext: { try await self.validate($0) })
    }
}
