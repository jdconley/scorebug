import Foundation
import libsrt
import XCTest
@testable import ScorebugStreaming
@testable import SRTHaishinKit

final class SRTProbeAuthorityBridgeTests: XCTestCase {
    func testAdapterCopyKeepsTheRevocableNativeAuthority() throws {
        var mon = CBytePerfMon(); mon.msRTT = 2
        let probe = try SRTBandwidthProbe(bitRate: 500_000, generation: 1,
            statistics: .init(mon: mon, sampledAt: 10), at: 10)
        let native = probe.snapshot(now: { 10 })
        let wrapped = PublishingBandwidthProbeSnapshot(native)
        XCTAssertNil(wrapped.stage)
        XCTAssertNil(wrapped.campaignStartedAt)
        XCTAssertNil(wrapped.totalAcceptedPayloadBytes)
        let authority = try XCTUnwrap(wrapped.authority)
        XCTAssertTrue(authority === native.authority)
        XCTAssertTrue(authority.permits(id: wrapped.id, generation: wrapped.publishingGeneration, stage: wrapped.stage))
        probe.cancel(.replaced)
        XCTAssertNil(wrapped.reason)
        XCTAssertFalse(authority.permits(id: wrapped.id, generation: wrapped.publishingGeneration, stage: wrapped.stage))
    }
    func testStagedAdapterCopyPreservesCampaignCountersAndAuthority() throws {
        var mon = CBytePerfMon(); mon.msRTT = 2
        let probe = try SRTBandwidthProbe(bitRate: 500_000, generation: 7,
            statistics: .init(mon: mon, sampledAt: 10), at: 10,
            stage: 2, campaignStartedAt: 9, previouslyAcceptedPayloadBytes: 2632)
        let native = probe.snapshot(now: { 10 })
        let wrapped = PublishingBandwidthProbeSnapshot(native)
        XCTAssertEqual(wrapped.stage, 2)
        XCTAssertEqual(wrapped.campaignStartedAt, 9)
        XCTAssertEqual(wrapped.totalAcceptedPayloadBytes, 2632)
        XCTAssertTrue(wrapped.authority === native.authority)
        let authority = try XCTUnwrap(wrapped.authority)
        XCTAssertTrue(authority.permits(id: wrapped.id, generation: 7, stage: 2))
        probe.cancel(.replaced)
        XCTAssertFalse(authority.permits(id: wrapped.id, generation: 7, stage: 2))
    }

}
