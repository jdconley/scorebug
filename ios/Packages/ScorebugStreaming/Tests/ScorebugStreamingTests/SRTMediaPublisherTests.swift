import Foundation
import XCTest
@testable import ScorebugStreaming

final class SRTMediaPublisherTests: XCTestCase {
    func testStopDuringConfigurationCannotStartConnectionLater() async throws {
        let fixture = AdapterFixture(gated: .configure)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        let start = Task { try await publisher.start() }
        await fixture.waitUntilEntered()
        await publisher.stop()
        do { try await start.value; XCTFail("Stopped start must not succeed") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.starts, 0)
        XCTAssertEqual(counts.stops, 2)
        let publishing = await publisher.isPublishing
        XCTAssertFalse(publishing)
    }

    func testStopDuringConnectIsTerminalEvenIfConnectionCompletesLate() async throws {
        let fixture = AdapterFixture(gated: .start)
        let publisher = SRTMediaPublisher(operations: await fixture.operations())
        let start = Task { try await publisher.start() }
        await fixture.waitUntilEntered()
        let stop = Task { await publisher.stop() }
        stop.cancel()
        await stop.value
        do { try await start.value; XCTFail("Stopped start must not succeed") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .cancelled) }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.stops, 2)
        let publishing = await publisher.isPublishing
        XCTAssertFalse(publishing)
        let transportAlive = await fixture.isHealthy()
        XCTAssertFalse(transportAlive, "Late reusable SDK start must be closed before stop returns")
        do { try await publisher.start(); XCTFail("One attempt only") }
        catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .invalidState) }
    }

    func testReadinessAndHealthAreObservedAndErrorsDoNotLeakUnderlyingDetails() async throws {
        for fails in [false, true] {
            let fixture = AdapterFixture(fails: fails)
            let publisher = SRTMediaPublisher(operations: await fixture.operations())
            if fails {
                do { try await publisher.start(); XCTFail("Should fail") }
                catch let error as SRTMediaPublisher.PublisherError { XCTAssertEqual(error, .startFailed) }
            } else {
                try await publisher.start()
                let ready = await publisher.isPublishing
                XCTAssertTrue(ready)
                await fixture.setHealthy(false)
                let failed = await publisher.isPublishing
                XCTAssertFalse(failed)
            }
            await publisher.stop()
            await publisher.stop()
            let counts = await fixture.counts()
            XCTAssertEqual(counts.stops, 1)
        }
    }
}

private actor AdapterFixture {
    enum Gate { case configure, start }
    private let gated: Gate?
    private let fails: Bool
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var healthy = false
    private var stopped = false
    private var starts = 0
    private var stops = 0
    init(gated: Gate? = nil, fails: Bool = false) { self.gated = gated; self.fails = fails }
    func operations() -> SRTMediaPublisher.Operations {
        .init(configure: { try await self.configure() }, start: { await self.start() },
              append: { _ in }, isPublishing: { await self.isHealthy() }, stop: { await self.stop() },
              setBitRate: { _ in }, metrics: { nil })
    }
    func configure() async throws {
        if fails { throw NSError(domain: "srt://private-secret", code: 1) }
        if gated == .configure { await wait() }
    }
    func start() async {
        starts += 1
        if gated == .start { await wait() }
        healthy = true // Model reusable SDK: a late start can reopen after close.
    }
    func isHealthy() -> Bool { healthy }
    func setHealthy(_ value: Bool) { healthy = value }
    func stop() {
        stops += 1; stopped = true; healthy = false
        continuation?.resume(); continuation = nil
    }
    func counts() -> (starts: Int, stops: Int) { (starts, stops) }
    private func wait() async {
        entered = true
        if stopped { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
}
