import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import ScorebugStreaming

final class PublishingVideoCostTests: XCTestCase {
    private let session = UUID()
    private func owner() -> PublishingVideoCostOwner {
        .init(scope: .init(recordingID: "r", matchID: "g", broadcastGeneration: 1,
                          publishingAttemptID: UUID(), appliedProfileRevision: 0))
    }
    private func frame(_ n: Int, to owner: PublishingVideoCostOwner, bytes: Int = 1000,
                       session: UUID? = nil, reverse: Bool = false, timeScale: Int32 = 30,
                       submitted: Double? = nil, latency: Double = 0.01) {
        let pts = CMTime(value: Int64(n), timescale: timeScale)
        let at = submitted ?? (100 + Double(n) / 30)
        let encoding = { owner.recordEncoding(sourcePTS: pts, outputPTS: pts, session: session ?? self.session,
            configuration: nil, submittedAt: at, completedAt: at + latency) }
        let compressed = { owner.recordCompressed(generation: 1, pts: pts, width: 960, height: 540,
            valid: true, bytes: bytes, dequeuedAt: at + latency + 0.001) }
        if reverse { compressed(); encoding() } else { encoding(); compressed() }
    }
    func testActualBytesExcludeAnchorAndPreserveTwoClocks() throws {
        let owner = owner()
        frame(0, to: owner, bytes: 999999)
        for n in 1...60 { frame(n, to: owner, bytes: n * 100, reverse: n % 2 == 0) }
        let window = try XCTUnwrap(owner.snapshot.intervals.last)
        XCTAssertEqual(window.frames, 60)
        XCTAssertEqual(window.payloadBytes, 183000)
        XCTAssertEqual(window.maximumFrameBytes, 6000)
        XCTAssertEqual(window.sourceDuration, 2, accuracy: 1e-9)
        XCTAssertEqual(window.submissionDuration, 2, accuracy: 1e-9)
        XCTAssertEqual(window.payloadBitsPerSecond, 732000, accuracy: 1e-6)
        XCTAssertNotNil(owner.fresh(at: 102.1))
        XCTAssertNil(owner.fresh(at: 104))
        owner.close()
        XCTAssertNil(owner.fresh(at: 102.1))
        XCTAssertTrue(owner.snapshot.isClosed)
        XCTAssertNil(owner.snapshot.invalidReason)
    }
    func testEquivalentRationalPTSAndOutOfOrderJoinCallbacks() throws {
        let owner = owner()
        for n in 0...60 {
            let t = CMTime(value: Int64(n * 2), timescale: 60), at = 100 + Double(n) / 30
            owner.recordCompressed(generation: 1, pts: t, width: 960, height: 540, valid: true, bytes: 1000, dequeuedAt: at + 0.02)
            owner.recordEncoding(sourcePTS: CMTime(value: Int64(n), timescale: 30), outputPTS: t, session: session,
                                 configuration: nil, submittedAt: at, completedAt: at + 0.01)
        }
        XCTAssertEqual(owner.snapshot.intervals.count, 1)
        XCTAssertNil(owner.snapshot.invalidReason)
    }
    func testSessionChangeCannotBorrowOldBytes() {
        let owner = owner(), next = UUID()
        for n in 0...30 { frame(n, to: owner) }
        for n in 31...90 { frame(n, to: owner, session: next) }
        XCTAssertTrue(owner.snapshot.intervals.isEmpty)
        frame(91, to: owner, session: next)
        XCTAssertEqual(owner.snapshot.intervals.last?.encoderSessionID, next)
        XCTAssertEqual(owner.snapshot.intervals.last?.payloadBytes, 60000)
    }
    func testDuplicateMissingInvalidAndOversizedEvidenceQuarantine() {
        for fault in 0..<5 {
            let owner = owner(); frame(0, to: owner)
            switch fault {
            case 0: frame(0, to: owner)
            case 1: frame(1, to: owner, bytes: 0)
            case 2: frame(1, to: owner, bytes: 16 * 1024 * 1024 + 1)
            case 3: frame(1, to: owner, latency: -1)
            default:
                for n in 1...65 { owner.recordCompressed(generation: 1, pts: CMTime(value: Int64(n), timescale: 30),
                    width: 960, height: 540, valid: true, bytes: 1000, dequeuedAt: 100 + Double(n) / 30) }
            }
            XCTAssertNotNil(owner.snapshot.invalidReason, "fault \(fault)")
            frame(70, to: owner)
            XCTAssertNil(owner.fresh(at: 103))
        }
        let owner = owner()
        owner.recordCompressed(generation: 1, pts: .zero, width: 960, height: 540, valid: true, bytes: 1000, dequeuedAt: 100)
        owner.close(); XCTAssertNotNil(owner.snapshot.invalidReason)
    }
    func testSlowSparseAndReversedClocksCannotBecomeUsable() {
        for fault in 0..<4 {
            let owner = owner()
            for n in 0...90 {
                frame(n, to: owner, timeScale: fault == 0 ? 15 : 30,
                      submitted: fault == 1 ? 100 + Double(n) / 15 : (fault == 2 ? 100 - Double(n) / 30 : nil),
                      latency: fault == 3 ? 2 : 0.01)
            }
            XCTAssertNil(owner.fresh(at: 106), "fault \(fault)")
            XCTAssertTrue(owner.snapshot.intervals.allSatisfy { !$0.usable }, "fault \(fault)")
        }
    }
    func testUnfinishedWindowAndReturningSessionCannotReuseOldCost() {
        let owner = owner()
        for n in 0...60 { frame(n, to: owner) }
        frame(61, to: owner, session: UUID())
        frame(62, to: owner)
        XCTAssertNil(owner.fresh(at: 102.2))
        let dense = self.owner()
        for n in 0...300 { frame(n, to: dense, timeScale: 1000) }
        XCTAssertNotNil(dense.snapshot.invalidReason)
    }

    func testPendingReplacementAndOrphanedEncodingCannotExposeCost() {
        let owner = owner()
        for n in 0...60 { frame(n, to: owner) }
        let next = CMTime(value: 61, timescale: 30)
        owner.recordEncoding(sourcePTS: next, outputPTS: next, session: UUID(), configuration: nil,
                             submittedAt: 102.033, completedAt: 102.04)
        XCTAssertNil(owner.fresh(at: 102.1))
        let missing = self.owner(); frame(0, to: missing)
        let first = CMTime(value: 1, timescale: 30)
        missing.recordEncoding(sourcePTS: first, outputPTS: first, session: session, configuration: nil,
                               submittedAt: 100.033, completedAt: 100.04)
        for n in 2...60 { frame(n, to: missing) }
        XCTAssertNotNil(missing.snapshot.invalidReason)
        XCTAssertNil(missing.fresh(at: 102.1))
    }

    func testHistoryAndPartialWindowRemainBounded() {
        let owner = owner()
        for n in 0...900 { frame(n, to: owner) }
        XCTAssertEqual(owner.snapshot.intervals.count, 8)
        XCTAssertEqual(owner.snapshot.intervals.last?.sequence, 15)
        frame(901, to: owner)
        XCTAssertEqual(owner.snapshot.intervals.count, 8)
        owner.close(); frame(902, to: owner)
        XCTAssertEqual(owner.snapshot.intervals.last?.sequence, 15)
    }
}
