import CoreMedia
import Foundation
import Darwin
import libsrt
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class SRTBandwidthProbeAdapterTests: XCTestCase {
    func testConnectedNativeAdapterRejectsLiveConfigureAndKeepsProbeDisabled() async throws {
        let adapter = SRTPublisher()
        try await adapter.configure()
        let listener = try ProbeTestListener()
        defer { listener.close() }
        let url = listener.url
        let start = Task { try await adapter.start(url) }
        do {
            try await listener.accept()
            try await start.value
            let healthy = await adapter.isPublishing()
            XCTAssertTrue(healthy)
            do { _ = try await adapter.beginBandwidthProbe(bitRate: 500_000); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
            do { try await adapter.configure(); XCTFail("configure must be pre-start only") }
            catch { XCTAssertEqual(error as? SRTPublisher.PublisherError, .notPublishing) }
            await adapter.stop()
        } catch {
            start.cancel()
            await adapter.stop()
            _ = await start.result
            throw error
        }
    }

    func testInactiveAndDefaultDisabledDoNotStartProbe() async throws {
        let native = SRTPublisher()
        do { _ = try await native.beginBandwidthProbe(bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .notPublishing) }
        await native.stop()
        let fixture = ProbeAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations(enabled: false))
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .notPublishing) }
        try await publisher.start()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .disabled) }
        let starts = await fixture.starts
        XCTAssertEqual(starts, 0)
        await publisher.stop()
    }

    func testExactIdentityAndTerminalDiagnosticsNeverRenew() async throws {
        let fixture = ProbeAdapterFixture()
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let probe = try await publisher.beginBandwidthProbe(bitRate: 500_000)
        for (id, generation) in [(UUID(), probe.publishingGeneration), (probe.id, probe.publishingGeneration + 1)] {
            do { _ = try await publisher.renewBandwidthProbe(id: id, publishingGeneration: generation); XCTFail() }
            catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
            await publisher.cancelBandwidthProbe(id: id, publishingGeneration: generation)
        }
        var renewals = await fixture.renewals
        XCTAssertEqual(renewals, 0)
        let renewed = try await publisher.renewBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration)
        XCTAssertEqual(renewed.leaseDeadline, 10.5)
        await publisher.cancelBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration)
        let terminal = await publisher.bandwidthProbeSnapshot()
        XCTAssertEqual(terminal?.reason, .cancelled)
        await publisher.stop()
        let retained = await publisher.bandwidthProbeSnapshot()
        XCTAssertEqual(retained?.id, probe.id)
        XCTAssertEqual(retained?.acceptedPayloadBytes, 1316)
        renewals = await fixture.renewals
        XCTAssertEqual(renewals, 1)
        do { _ = try await publisher.renewBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .notPublishing) }
    }

    func testStopJoinsAndRevokesLateAdmission() async throws {
        let fixture = ProbeAdapterFixture(gate: .begin)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let begin = Task { try await publisher.beginBandwidthProbe(bitRate: 500_000) }
        await fixture.waitUntilEntered()
        await publisher.stop() // Fixture close releases the gated native admission.
        let snapshot = await fixture.snapshot
        XCTAssertNotNil(snapshot?.reason)
        let stopped = await fixture.stopped
        XCTAssertTrue(stopped)
        let starts = await fixture.starts
        XCTAssertEqual(starts, 1)
        let cancels = await fixture.cancels
        XCTAssertGreaterThanOrEqual(cancels, 1, "Late admission must be revoked before stop returns; repeated close is idempotent")
        do { _ = try await begin.value; XCTFail() } catch {}
    }

    func testCancelledAdmissionRevokesWithoutStoppingMedia() async throws {
        let fixture = ProbeAdapterFixture(gate: .begin)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let begin = Task { try await publisher.beginBandwidthProbe(bitRate: 500_000) }
        await fixture.waitUntilEntered()
        begin.cancel()
        await fixture.release()
        do { _ = try await begin.value; XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .cancelled) }
        let snapshot = await fixture.snapshot
        XCTAssertEqual(snapshot?.reason, .cancelled)
        let healthy = await publisher.isPublishing
        XCTAssertTrue(healthy)
        await publisher.stop()
    }

    func testCancelledRenewalRevokesExistingLeaseEvenWhenOperationThrows() async throws {
        let fixture = ProbeAdapterFixture(gate: .renew, failRenewal: true)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let probe = try await publisher.beginBandwidthProbe(bitRate: 500_000)
        let renew = Task { try await publisher.renewBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration) }
        await fixture.waitUntilEntered()
        renew.cancel()
        await fixture.release()
        do { _ = try await renew.value; XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .cancelled) }
        let terminal = await fixture.snapshot
        XCTAssertEqual(terminal?.reason, .cancelled)
        let healthy = await publisher.isPublishing
        XCTAssertTrue(healthy)
        await publisher.stop()
    }

    func testConcurrentStartIsRejected() async throws {
        let fixture = ProbeAdapterFixture(gate: .begin)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let begin = Task { try await publisher.beginBandwidthProbe(bitRate: 500_000) }
        await fixture.waitUntilEntered()
        do { _ = try await publisher.beginBandwidthProbe(bitRate: 500_000); XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .busy) }
        await fixture.release()
        _ = try await begin.value
        await publisher.stop()
    }

    func testSettingsChangeDuringAdmissionRejectsAndRevokesLateHandle() async throws {
        let fixture = ProbeAdapterFixture(gate: .begin)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        try await publisher.start()
        let begin = Task { try await publisher.beginBandwidthProbe(bitRate: 500_000) }
        await fixture.waitUntilEntered()
        try await publisher.setBitRate(1_000_000)
        await fixture.release()
        do { _ = try await begin.value; XCTFail() }
        catch { XCTAssertEqual(error as? PublishingBandwidthProbeError, .obsolete) }
        let snapshot = await fixture.snapshot
        XCTAssertEqual(snapshot?.reason, .cancelled)
        await publisher.stop()
    }

    func testSettingsChangeOrStopDuringRenewalCannotAcknowledgeActiveLease() async throws {
        for stop in [false, true] {
            let fixture = ProbeAdapterFixture(gate: .renew)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            try await publisher.start()
            let probe = try await publisher.beginBandwidthProbe(bitRate: 500_000)
            let renew = Task { try await publisher.renewBandwidthProbe(id: probe.id, publishingGeneration: probe.publishingGeneration) }
            await fixture.waitUntilEntered()
            if stop { await publisher.stop() }
            else { try await publisher.setBitRate(1_000_000); await fixture.release() }
            do { _ = try await renew.value; XCTFail() } catch {}
            let snapshot = await fixture.snapshot
            XCTAssertNotNil(snapshot?.reason)
            await publisher.stop()
        }
    }
}

private actor ProbeAdapterFixture {
    enum Gate { case begin, renew }
    private let gate: Gate?
    private let failRenewal: Bool
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var starts = 0, renewals = 0, cancels = 0
    private(set) var stopped = false
    private(set) var snapshot: PublishingBandwidthProbeSnapshot?
    init(gate: Gate? = nil, failRenewal: Bool = false) { self.gate = gate; self.failRenewal = failRenewal }
    func operations(enabled: Bool = true) -> SRTMediaPublisher.Operations {
        var operations = SRTMediaPublisher.Operations(configure: {}, start: {}, append: { _ in },
            isPublishing: { await !self.stopped }, stop: { await self.stop() },
            setBitRate: { rate in
                PublishingBitRateChange(publishingGeneration: 7,
                    configuration: VideoEncodingConfiguration(id: UUID(), encoderSessionID: UUID(), bitRate: rate)!,
                    acceptedAt: 10, lastSubmittedSourcePTS: CMTime(value: 1, timescale: 30))!
            }, metrics: { nil })
        if enabled {
            operations.beginProbe = { try await self.begin($0) }
            operations.renewProbe = { try await self.renew($0, generation: $1) }
            operations.cancelProbe = { await self.cancel($0, generation: $1) }
            operations.probeSnapshot = { await self.snapshot }
        }
        return operations
    }
    func begin(_ rate: Int) async throws -> PublishingBandwidthProbeSnapshot {
        starts += 1
        if gate == .begin { await wait() }
        let value = PublishingBandwidthProbeSnapshot(id: UUID(), publishingGeneration: 7,
            bitRate: rate, startedAt: 10, leaseDeadline: 10.3,
            acceptedPayloadBytes: 1316, lastAcceptedAt: 10.1, reason: nil)
        snapshot = value // Deliberately model a late SDK result, even after close.
        return value
    }
    func renew(_ id: UUID, generation: UInt64) async throws -> PublishingBandwidthProbeSnapshot {
        renewals += 1
        if gate == .renew { await wait() }
        if failRenewal { throw CancellationError() }
        let prior = snapshot!
        let value = PublishingBandwidthProbeSnapshot(id: prior.id, publishingGeneration: prior.publishingGeneration,
            bitRate: prior.bitRate, startedAt: prior.startedAt, leaseDeadline: 10.5,
            acceptedPayloadBytes: prior.acceptedPayloadBytes, lastAcceptedAt: prior.lastAcceptedAt, reason: prior.reason)
        snapshot = value
        return value
    }
    func cancel(_ id: UUID, generation: UInt64) {
        guard let prior = snapshot, prior.id == id, prior.publishingGeneration == generation else { return }
        cancels += 1
        snapshot = .init(id: prior.id, publishingGeneration: prior.publishingGeneration,
            bitRate: prior.bitRate, startedAt: prior.startedAt, leaseDeadline: prior.leaseDeadline,
            acceptedPayloadBytes: prior.acceptedPayloadBytes, lastAcceptedAt: prior.lastAcceptedAt,
            reason: prior.reason ?? .cancelled)
    }
    func stop() {
        stopped = true
        if let value = snapshot { cancel(value.id, generation: value.publishingGeneration) }
        release()
    }
    func release() { waiter?.resume(); waiter = nil }
    private func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
}

/// Ephemeral loopback endpoint, no media queue or detached task. The SDK adapter
/// initializes process-wide libSRT first; this helper owns only its descriptors.
private final class ProbeTestListener {
    private let socket: SRTSOCKET
    private var peer: SRTSOCKET = SRT_INVALID_SOCK
    let url: URL
    init() throws {
        let socket = srt_create_socket()
        self.socket = socket
        guard socket != SRT_INVALID_SOCK else { throw Failure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var blocking = false
        guard srt_setsockflag(socket, SRTO_RCVSYN, &blocking, Int32(MemoryLayout<Bool>.size)) == 0 else {
            srt_close(socket); throw Failure.socket
        }
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, srt_listen(socket, 1) == 0 else { srt_close(socket); throw Failure.socket }
        var size = Int32(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_getsockname(socket, $0, &size) }
        }
        guard named == 0 else { srt_close(socket); throw Failure.socket }
        url = URL(string: "srt://127.0.0.1:\(UInt16(bigEndian: address.sin_port))?mode=caller")!
    }
    func accept() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let accepted = srt_accept(socket, nil, nil)
            if accepted != SRT_INVALID_SOCK { peer = accepted; return }
            guard srt_getlasterror(nil) == SRT_EASYNCRCV.rawValue else { throw Failure.socket }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timeout
    }
    func close() {
        if peer != SRT_INVALID_SOCK { srt_close(peer); peer = SRT_INVALID_SOCK }
        srt_close(socket)
    }
    enum Failure: Error { case socket, timeout }
}
