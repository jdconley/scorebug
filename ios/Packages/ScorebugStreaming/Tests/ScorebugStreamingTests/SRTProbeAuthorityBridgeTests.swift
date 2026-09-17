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
        let authority = try XCTUnwrap(wrapped.authority)
        XCTAssertTrue(authority === native.authority)
        XCTAssertTrue(authority.permits(id: wrapped.id, generation: wrapped.publishingGeneration, stage: wrapped.stage))
        probe.cancel(.replaced)
        XCTAssertNil(wrapped.reason)
        XCTAssertFalse(authority.permits(id: wrapped.id, generation: wrapped.publishingGeneration, stage: wrapped.stage))
    }
}
