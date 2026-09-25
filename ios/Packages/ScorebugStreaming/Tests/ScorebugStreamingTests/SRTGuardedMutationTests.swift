import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class SRTGuardedMutationTests: XCTestCase {
    func testMissingGuardedCapabilitiesNeverCallsLegacyMutation() async throws {
        for missing in ["rate", "profile", "validation"] {
            let fixture = GuardedMutationFixture()
            var operations = await fixture.operations()
            if missing == "rate" { operations.setBitRateExpecting = nil }
            if missing == "profile" { operations.setProfileExpecting = nil }
            if missing == "validation" { operations.validateVideoMutationExpectation = nil }
            let publisher = SRTMediaPublisher(operations: operations)
            try await publisher.start()
            if missing != "profile" {
                await rejects(.unavailable) { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
            } else {
                await rejects(.unavailable) { _ = try await publisher.setVideoProfile(.sd540, expecting: guardedReceipt()) }
            }
            let counts = await fixture.counts
            XCTAssertEqual(counts.legacy, 0); XCTAssertEqual(counts.guarded, 0); XCTAssertEqual(counts.stop, 0)
            await publisher.stop()
        }
    }

    func testStalePreflightAndGuardedDispatchPreserveHealthyPublication() async throws {
        for profile in [false, true] {
            for duringDispatch in [false, true] {
                let fixture = GuardedMutationFixture()
                await fixture.reject(duringDispatch ? .dispatch : .validation)
                let publisher = SRTMediaPublisher(operations: await fixture.operations())
                try await publisher.start()
                await rejects(.stale) {
                    if profile { _ = try await publisher.setVideoProfile(.sd540, expecting: guardedReceipt()) }
                    else { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
                }
                let healthy = await publisher.isPublishing
                XCTAssertTrue(healthy)
                let counts = await fixture.counts
                XCTAssertEqual(counts.stop, 0); XCTAssertEqual(counts.legacy, 0)
                XCTAssertEqual(counts.guarded, duringDispatch ? 1 : 0)
                await fixture.reject(nil)
                _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt()))
                await publisher.stop()
            }
        }
    }

    func testHeldPreflightCannotOverwriteNewMutationOrStop() async throws {
        for stopping in [false, true] {
            for health in [false, true] {
                let fixture = GuardedMutationFixture()
                let publisher = SRTMediaPublisher(operations: await fixture.operations())
                try await publisher.start()
                await fixture.hold(health ? .health : .validation)
                let old = Task { try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
                await fixture.waitForEntry()
                if stopping { await publisher.stop() }
                else { _ = try await publisher.setVideoBitRate(900_000) }
                await fixture.release()
                if case .success = await old.result { XCTFail("Old preflight survived configuration change") }
                let counts = await fixture.counts
                XCTAssertEqual(counts.guarded, 0)
                if !stopping { XCTAssertEqual(counts.stop, 0) }
                await publisher.stop()
            }
        }
    }

    func testUncertainGuardedFailureAndCancellationJoinShutdown() async throws {
        for profile in [false, true] {
            for cancelled in [false, true] {
                let fixture = GuardedMutationFixture()
                let publisher = SRTMediaPublisher(operations: await fixture.operations())
                try await publisher.start()
                if cancelled { await fixture.hold(.dispatch) }
                else { await fixture.reject(.uncertain) }
                let pending = Task {
                    if profile { _ = try await publisher.setVideoProfile(.sd540, expecting: guardedReceipt()) }
                    else { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
                }
                if cancelled { await fixture.waitForEntry(); pending.cancel(); await fixture.release() }
                if case .success = await pending.result { XCTFail("Uncertain mutation succeeded") }
                let healthy = await publisher.isPublishing
                XCTAssertFalse(healthy)
                let counts = await fixture.counts
                XCTAssertGreaterThan(counts.stop, 0)
                await publisher.stop()
            }
        }
    }

    func testStopAndCancellationWinOverLateSafePreflightRejection() async throws {
        for stopping in [false, true] {
            let fixture = GuardedMutationFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            await fixture.hold(.validation)
            await fixture.reject(.validation)
            let pending = Task { try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
            await fixture.waitForEntry()
            if stopping { await publisher.stop() } else { pending.cancel() }
            await fixture.release()
            do { _ = try await pending.value; XCTFail() }
            catch { XCTAssertEqual(error as? SRTMediaPublisher.PublisherError, .cancelled) }
            let counts = await fixture.counts
            XCTAssertEqual(counts.guarded, 0)
            await publisher.stop()
        }
    }

    func testInvalidGuardedReceiptRequiresJoinedShutdown() async throws {
        let fixture = GuardedMutationFixture()
        var operations = await fixture.operations()
        operations.setBitRateExpecting = { _, _ in guardedReceipt() } // Old rate after claimed success.
        let publisher = SRTMediaPublisher(operations: operations)
        try await publisher.start()
        do { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())); XCTFail() }
        catch { XCTAssertNil(error as? PublishingVideoMutationAdmissionError) }
        let healthy = await publisher.isPublishing
        XCTAssertFalse(healthy)
        await publisher.stop()
    }

    func testCachedReceiptForSameRateIsUncertainFailure() async throws {
        let fixture = GuardedMutationFixture()
        var operations = await fixture.operations()
        operations.setBitRateExpecting = { _, _ in guardedReceipt() }
        let publisher = SRTMediaPublisher(operations: operations)
        try await publisher.start()
        do { _ = try await publisher.setVideoBitRate(600_000, expecting: .verified(guardedReceipt())); XCTFail() }
        catch { XCTAssertEqual(error as? SRTMediaPublisher.PublisherError, .bitRateUpdateFailed) }
        let healthy = await publisher.isPublishing
        XCTAssertFalse(healthy)
        await publisher.stop()
    }

    func testStopDuringHeldDispatchWinsOverLateSafeErrorAndJoins() async throws {
        for profile in [false, true] {
            let fixture = GuardedMutationFixture()
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            await fixture.hold(.dispatch); await fixture.reject(.dispatch)
            let mutation = Task {
                if profile { _ = try await publisher.setVideoProfile(.sd540, expecting: guardedReceipt()) }
                else { _ = try await publisher.setVideoBitRate(800_000, expecting: .verified(guardedReceipt())) }
            }
            await fixture.waitForEntry()
            let stopping = Task { await publisher.stop() }
            let deadline = ContinuousClock.now + .seconds(2)
            while await fixture.counts.stop == 0, ContinuousClock.now < deadline { await Task.yield() }
            await fixture.release()
            do { try await mutation.value; XCTFail() }
            catch { XCTAssertEqual(error as? SRTMediaPublisher.PublisherError, .cancelled) }
            await stopping.value
            let healthy = await publisher.isPublishing
            XCTAssertFalse(healthy)
        }
    }

    private func rejects(_ expected: PublishingVideoMutationAdmissionError,
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected safe admission rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? PublishingVideoMutationAdmissionError, expected, file: file, line: line) }
    }
}

private let guardedConfigurationID = UUID(), guardedEncoderID = UUID()
private func guardedReceipt(rate: Int = 600_000, configuration: UUID = guardedConfigurationID) -> PublishingBitRateChange {
    .init(publishingGeneration: 7, configuration: .init(id: configuration, encoderSessionID: guardedEncoderID, bitRate: rate)!,
        acceptedAt: 10, lastSubmittedSourcePTS: CMTime(value: 30, timescale: 30))!
}
private actor GuardedMutationFixture {
    enum Point { case health, validation, dispatch, uncertain }
    var counts = (legacy: 0, guarded: 0, stop: 0)
    var rejection: Point?
    var held: Point?
    var gate: CheckedContinuation<Void, Never>?
    var entered = false
    func reject(_ point: Point?) { rejection = point }
    func hold(_ point: Point) { held = point; entered = false }
    func waitForEntry() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    func release() { gate?.resume(); gate = nil }
    func pause(_ point: Point) async {
        if held == point { held = nil; entered = true; await withCheckedContinuation { gate = $0 } }
    }
    func health() async -> Bool { await pause(.health); return true }
    func validate(_ expected: PublishingVideoMutationExpectation) async throws {
        await pause(.validation)
        if rejection == .validation { throw PublishingVideoMutationAdmissionError.stale }
    }
    func write(rate: Int = 800_000) async throws -> PublishingBitRateChange {
        counts.guarded += 1
        await pause(.dispatch)
        if rejection == .dispatch { throw PublishingVideoMutationAdmissionError.stale }
        if rejection == .uncertain { throw SRTMediaPublisher.PublisherError.bitRateUpdateFailed }
        return guardedReceipt(rate: rate, configuration: UUID())
    }
    func profile() async throws -> PublishingVideoProfileChange {
        _ = try await write()
        return .init(profile: .sd540, publishingGeneration: 7, previousEncoderSessionID: guardedEncoderID,
            encoderSessionID: UUID(), lastOldSourcePTS: .zero, firstNewSourcePTS: CMTime(value: 1, timescale: 30),
            width: 960, height: 540, rawVideoFramesDropped: 0, acknowledgedAt: 11)!
    }
    func legacy() -> PublishingBitRateChange { counts.legacy += 1; return guardedReceipt() }
    func stop() { counts.stop += 1 }
    func operations() -> SRTMediaPublisher.Operations {
        var value = SRTMediaPublisher.Operations(configure: {}, start: {}, append: { _ in },
            isPublishing: { await self.health() }, stop: { await self.stop() },
            setBitRate: { _ in await self.legacy() }, metrics: { nil })
        value.validateVideoMutationExpectation = { try await self.validate($0) }
        value.setBitRateExpecting = { rate, _ in try await self.write(rate: rate) }
        value.setProfileExpecting = { _, _ in try await self.profile() }
        return value
    }
}
