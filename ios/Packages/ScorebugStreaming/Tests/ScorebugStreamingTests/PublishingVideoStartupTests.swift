import CoreMedia
import Foundation
import XCTest
@testable import ScorebugStreaming
import ScorebugMedia

final class PublishingVideoStartupTests: XCTestCase {
    private let encoder = UUID()
    private let pts = CMTime(value: 300, timescale: 30)
    private func encoded(_ owner: PublishingVideoStartupOwner, pts: CMTime? = nil, output: CMTime? = nil,
                         submitted: Double = 10, completed: Double = 10.1) {
        owner.recordEncoding(sourcePTS: pts ?? self.pts, outputPTS: output ?? pts ?? self.pts,
            encoderSessionID: encoder, submittedAt: submitted, completedAt: completed)
    }
    private func compressed(_ owner: PublishingVideoStartupOwner, pts: CMTime? = nil,
                            width: Int = 426, height: Int = 240, generation: UInt64 = 1,
                            valid: Bool = true, sync: Bool = true, at: Double = 10.2) {
        owner.recordCompressed(sourcePTS: pts ?? self.pts, publishingGeneration: generation,
            width: width, height: height, valid: valid, isSync: sync, dequeuedAt: at)
    }
    func testJoinsFirstCallbacksInEitherOrderAndPreservesActualIdentity() throws {
        for reversed in [false, true] {
            let owner = PublishingVideoStartupOwner(profile: .low240)
            XCTAssertNil(owner.snapshot.receipt)
            if reversed { compressed(owner); encoded(owner) } else { encoded(owner); compressed(owner) }
            let proof = try XCTUnwrap(owner.snapshot.receipt)
            XCTAssertEqual(proof.profile, .low240)
            XCTAssertEqual(proof.width, 426); XCTAssertEqual(proof.height, 240)
            XCTAssertEqual(proof.encoderSessionID, encoder)
            XCTAssertEqual(proof.publishingGeneration, 1)
            XCTAssertEqual(CMTimeCompare(proof.firstSourcePTS, pts), 0)
            XCTAssertEqual(proof.submittedAt, 10); XCTAssertEqual(proof.completedAt, 10.1)
            XCTAssertEqual(proof.observedAt, 10.2)
            XCTAssertNil(owner.snapshot.invalidReason)
        }
    }
    func testLaterCallbacksCannotReplaceFirstFrameOrRetainUnboundedHistory() throws {
        let owner = PublishingVideoStartupOwner(profile: .low240)
        encoded(owner)
        for i in 1...1000 { encoded(owner, pts: CMTime(value: 300 + Int64(i), timescale: 30)) }
        compressed(owner)
        let first = try XCTUnwrap(owner.snapshot.receipt)
        for i in 1...1000 { compressed(owner, pts: CMTime(value: 300 + Int64(i), timescale: 30), width: 1920, height: 1080) }
        XCTAssertEqual(owner.snapshot.receipt, first)
    }
    func testWrongFirstDimensionsNeverHealWithLaterMinimumFrame() {
        let owner = PublishingVideoStartupOwner(profile: .low240)
        encoded(owner); compressed(owner, width: 1920, height: 1080)
        XCTAssertNil(owner.snapshot.receipt); XCTAssertNotNil(owner.snapshot.invalidReason)
        encoded(owner); compressed(owner)
        XCTAssertNil(owner.snapshot.receipt)
    }
    func testWrongPTSInvalidFormatNonSyncAndGenerationCannotProveStartup() {
        for mode in 0..<6 {
            let owner = PublishingVideoStartupOwner(profile: .low240)
            encoded(owner, output: mode == 0 ? .zero : nil)
            compressed(owner, pts: mode == 1 ? .zero : nil, width: mode == 2 ? 0 : 426,
                generation: mode == 3 ? 0 : 1, valid: mode != 4, sync: mode != 5)
            XCTAssertNil(owner.snapshot.receipt); XCTAssertNotNil(owner.snapshot.invalidReason)
        }
    }
    func testClockReversalNonFiniteOrNonzeroEpochCannotProveStartup() {
        for mode in 0..<5 {
            let owner = PublishingVideoStartupOwner(profile: .low240)
            encoded(owner, pts: mode == 0 ? CMTime(value: 300, timescale: 30, flags: .valid, epoch: 1) : nil,
                submitted: mode == 1 ? .nan : 10, completed: mode == 2 ? 9 : 10.1)
            compressed(owner, at: mode == 3 ? 10.05 : mode == 4 ? .infinity : 10.2)
            XCTAssertNil(owner.snapshot.receipt); XCTAssertNotNil(owner.snapshot.invalidReason)
        }
    }
    func testCloseCannotResurrectPendingAndNewAttemptOwnsIndependentEvidence() {
        let old = PublishingVideoStartupOwner(profile: .hd1080)
        encoded(old); old.close(); compressed(old, width: 1920, height: 1080)
        XCTAssertTrue(old.snapshot.isClosed); XCTAssertNil(old.snapshot.receipt)
        let fresh = PublishingVideoStartupOwner(profile: .low240)
        encoded(fresh); compressed(fresh)
        XCTAssertNotNil(fresh.snapshot.receipt)
        fresh.close()
        XCTAssertTrue(fresh.snapshot.isClosed); XCTAssertNotNil(fresh.snapshot.receipt)
    }
    func testRationallyEquivalentSourceCoordinatesJoin() {
        let owner = PublishingVideoStartupOwner(profile: .low240)
        encoded(owner); compressed(owner, pts: CMTime(value: 10, timescale: 1))
        XCTAssertNotNil(owner.snapshot.receipt)
    }
}
