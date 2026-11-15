import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class SRTStreamPublisherTests: XCTestCase {
    func testStartConfiguresInitialProfileThenConnects() async throws {
        let fixture = Fixture()
        let publisher = SRTStreamPublisher(operations: fixture.operations, profile: .hd720)
        try await publisher.start()
        XCTAssertEqual(fixture.events, ["configure:720p30", "start"])
        let healthy = await publisher.isPublishing
        XCTAssertTrue(healthy)
        await publisher.stop()
        XCTAssertEqual(fixture.events.last, "stop")
        let after = await publisher.isPublishing
        XCTAssertFalse(after)
    }

    func testStartFailureIsSanitizedAndClosesTransport() async throws {
        let fixture = Fixture(startFails: true)
        let publisher = SRTStreamPublisher(operations: fixture.operations, profile: .hd720)
        do { try await publisher.start(); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? SRTStreamPublisher.PublisherError, .startFailed) }
        XCTAssertEqual(fixture.events.filter { $0 == "stop" }.count, 1)
        do { try await publisher.start(); XCTFail("not reusable") }
        catch { XCTAssertEqual(error as? SRTStreamPublisher.PublisherError, .invalidState) }
    }

    func testProfileChangeAndStatisticsRequirePublishing() async throws {
        let fixture = Fixture()
        let publisher = SRTStreamPublisher(operations: fixture.operations, profile: .hd720)
        do { try await publisher.setVideoProfile(.sd540); XCTFail("not publishing") }
        catch { XCTAssertEqual(error as? SRTStreamPublisher.PublisherError, .notPublishing) }
        let before = await publisher.transportStatistics()
        XCTAssertNil(before)
        try await publisher.start()
        try await publisher.setVideoProfile(.sd540)
        XCTAssertTrue(fixture.events.contains("profile:540p30"))
        let stats = await publisher.transportStatistics()
        XCTAssertEqual(stats?.senderBufferMilliseconds, 40)
        await publisher.stop()
        let after = await publisher.transportStatistics()
        XCTAssertNil(after)
    }

    func testFailedProfileChangeStopsThePublisher() async throws {
        let fixture = Fixture(profileFails: true)
        let publisher = SRTStreamPublisher(operations: fixture.operations, profile: .hd720)
        try await publisher.start()
        do { try await publisher.setVideoProfile(.sd540); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? SRTStreamPublisher.PublisherError, .profileUpdateFailed) }
        XCTAssertEqual(fixture.events.last, "stop")
        let healthy = await publisher.isPublishing
        XCTAssertFalse(healthy)
    }

    func testStopDuringStartupIsTerminal() async throws {
        let fixture = Fixture(blocksStart: true)
        let publisher = SRTStreamPublisher(operations: fixture.operations, profile: .hd720)
        let starting = Task { try await publisher.start() }
        while !fixture.events.contains("start") { await Task.yield() }
        await publisher.stop()
        do { try await starting.value; XCTFail("stopped start cannot succeed") }
        catch { XCTAssertEqual(error as? SRTStreamPublisher.PublisherError, .cancelled) }
        let healthy = await publisher.isPublishing
        XCTAssertFalse(healthy)
    }

    func testNativePublisherIsInertBeforeConnecting() async {
        let publisher = SRTStreamPublisher(url: URL(string: "srt://127.0.0.1:9")!, profile: .hd720)
        let healthy = await publisher.isPublishing
        XCTAssertFalse(healthy)
        let stats = await publisher.transportStatistics()
        XCTAssertNil(stats)
        await publisher.stop()
    }
}

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var active = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    let startFails: Bool, profileFails: Bool, blocksStart: Bool
    init(startFails: Bool = false, profileFails: Bool = false, blocksStart: Bool = false) {
        self.startFails = startFails; self.profileFails = profileFails; self.blocksStart = blocksStart
    }
    var events: [String] { lock.withLock { log } }
    private func record(_ event: String) { lock.withLock { log.append(event) } }
    var operations: SRTStreamPublisher.Operations {
        .init(configure: { self.record("configure:\($0.rawValue)") },
              start: {
                  self.record("start")
                  if self.blocksStart {
                      await withCheckedContinuation { pending in
                          let resume = self.lock.withLock { () -> Bool in
                              if self.stopped { return true }
                              self.startWaiter = pending; return false
                          }
                          if resume { pending.resume() }
                      }
                      throw CancellationError()
                  }
                  if self.startFails { throw URLError(.cannotConnectToHost) }
                  self.lock.withLock { self.active = true }
              },
              append: { _ in },
              isPublishing: { self.lock.withLock { self.active } },
              stop: {
                  self.record("stop")
                  let waiter = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                      self.active = false; self.stopped = true
                      let value = self.startWaiter; self.startWaiter = nil; return value
                  }
                  waiter?.resume()
              },
              setProfile: {
                  self.record("profile:\($0.rawValue)")
                  if self.profileFails { throw URLError(.networkConnectionLost) }
              },
              statistics: {
                  .init(sampledAt: 1, sentPackets: 10, retransmittedPackets: 0, droppedPackets: 0,
                        senderBufferMilliseconds: 40, rttMilliseconds: 20, sendRateMbps: 3)
              })
    }
}
