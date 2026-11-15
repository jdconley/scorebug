import ScorebugCore
import XCTest

final class QualityLadderTests: XCTestCase {
    /// Synthetic SRT sender feed sampled every half second.
    private struct Feed {
        var time = 0.0
        var sent: Int64 = 0
        var retransmitted: Int64 = 0
        var dropped: Int64 = 0
        mutating func next(bufferMs: Int = 120, packets: Int64 = 150, retransmits: Int64 = 0, drops: Int64 = 0,
                           step: Double = 0.5) -> QualityLadder.Sample {
            time += step; sent += packets; retransmitted += retransmits; dropped += drops
            return .init(time: time, senderBufferMilliseconds: bufferMs, sentPackets: sent,
                         retransmittedPackets: retransmitted, droppedPackets: dropped)
        }
    }

    private func run(_ ladder: inout QualityLadder, _ feed: inout Feed, seconds: Double,
                     thermal: QualityLadder.Thermal = .nominal,
                     sample: (inout Feed) -> QualityLadder.Sample) -> [QualityLadder.Rung] {
        var changes: [QualityLadder.Rung] = []
        let end = feed.time + seconds
        while feed.time < end - 1e-9 {
            if let rung = ladder.observe(sample(&feed), thermal: thermal) { changes.append(rung) }
        }
        return changes
    }

    func testRungsMatchTheProfileTable() {
        XCTAssertEqual(QualityLadder.Rung.allCases.map(\.label), ["360p", "540p", "720p", "1080p"])
        XCTAssertEqual(QualityLadder.Rung.allCases.map(\.videoBitRate), [800_000, 1_600_000, 3_000_000, 6_000_000])
        XCTAssertEqual(QualityLadder.Rung.p720.width, 1280)
        XCTAssertEqual(QualityLadder.Rung.fitting(height: 2160), .p1080)
        XCTAssertEqual(QualityLadder.Rung.fitting(height: 1080), .p1080)
        XCTAssertEqual(QualityLadder.Rung.fitting(height: 720), .p720)
    }

    func testStartsAt720pAndNeverAboveMaximum() {
        XCTAssertEqual(QualityLadder().current, .p720)
        XCTAssertEqual(QualityLadder(maximum: .p540).current, .p540)
        var ladder = QualityLadder(maximum: .p720)
        var feed = Feed()
        let changes = run(&ladder, &feed, seconds: 120) { $0.next(bufferMs: 50) }
        XCTAssertEqual(changes, [])
        XCTAssertEqual(ladder.current, .p720)
    }

    func testSustainedSendBufferPressureStepsDownAfterThreeSeconds() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 5) { $0.next() }
        XCTAssertEqual(run(&ladder, &feed, seconds: 2.5) { $0.next(bufferMs: 1200) }, [])
        XCTAssertEqual(ladder.current, .p720, "2.5 s of pressure is not sustained")
        XCTAssertEqual(run(&ladder, &feed, seconds: 1) { $0.next(bufferMs: 1200) }, [.p540])
    }

    func testBriefPressureSpikesDoNotStepDown() {
        var ladder = QualityLadder()
        var feed = Feed()
        for _ in 0..<20 {
            _ = run(&ladder, &feed, seconds: 2) { $0.next(bufferMs: 1500) }
            _ = run(&ladder, &feed, seconds: 1) { $0.next() }
        }
        XCTAssertEqual(ladder.current, .p720)
    }

    func testRetransmitRatioAndSenderDropsAreDownwardPressure() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 1) { $0.next() }
        XCTAssertEqual(run(&ladder, &feed, seconds: 3.5) { $0.next(packets: 150, retransmits: 30) }, [.p540])
        var dropping = QualityLadder()
        var other = Feed()
        _ = run(&dropping, &other, seconds: 1) { $0.next() }
        XCTAssertEqual(run(&dropping, &other, seconds: 3.5) { $0.next(drops: 2) }, [.p540])
    }

    func testContinuedPressureWalksDownToTheBottomRung() {
        var ladder = QualityLadder()
        var feed = Feed()
        let changes = run(&ladder, &feed, seconds: 30) { $0.next(bufferMs: 2000) }
        XCTAssertEqual(changes, [.p540, .p360])
        XCTAssertEqual(ladder.current, .p360)
    }

    func testStepsUpAfterTwentySecondsOfHeadroom() {
        var ladder = QualityLadder()
        var feed = Feed()
        XCTAssertEqual(run(&ladder, &feed, seconds: 20) { $0.next(bufferMs: 80) }, [])
        XCTAssertEqual(run(&ladder, &feed, seconds: 1) { $0.next(bufferMs: 80) }, [.p1080])
        XCTAssertEqual(run(&ladder, &feed, seconds: 60) { $0.next(bufferMs: 80) }, [], "already at maximum")
    }

    func testNeutralSamplesResetHeadroomCredit() {
        var ladder = QualityLadder()
        var feed = Feed()
        for _ in 0..<5 {
            _ = run(&ladder, &feed, seconds: 15) { $0.next(bufferMs: 80) }
            _ = run(&ladder, &feed, seconds: 1) { $0.next(bufferMs: 500) }
        }
        XCTAssertEqual(ladder.current, .p720)
    }

    func testNeverStepsUpWithinThirtySecondsOfAStepDown() {
        var ladder = QualityLadder()
        var feed = Feed()
        XCTAssertEqual(run(&ladder, &feed, seconds: 3.5) { $0.next(bufferMs: 1500) }.last, .p540)
        let downAt = feed.time
        let changes = run(&ladder, &feed, seconds: 40) { $0.next(bufferMs: 80) }
        XCTAssertEqual(changes, [.p720])
        // Headroom credit was earned by 20 s; the step up had to wait for the holdoff.
        var upAt = downAt
        var replay = QualityLadder()
        var replayFeed = Feed()
        _ = run(&replay, &replayFeed, seconds: 3.5) { $0.next(bufferMs: 1500) }
        while replay.current == .p540 { _ = replay.observe(replayFeed.next(bufferMs: 80), thermal: .nominal); upAt = replayFeed.time }
        XCTAssertGreaterThanOrEqual(upAt - downAt, 30)
    }

    func testSeriousThermalStepsDownOnceAndCapsAt720p() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 21) { $0.next(bufferMs: 80) }
        XCTAssertEqual(ladder.current, .p1080)
        XCTAssertEqual(run(&ladder, &feed, seconds: 120, thermal: .serious) { $0.next(bufferMs: 80) }, [.p720])
        XCTAssertEqual(ladder.cap, .p720)
        // Cooling lifts the cap; the normal headroom and holdoff rules then apply.
        let cooled = run(&ladder, &feed, seconds: 40, thermal: .fair) { $0.next(bufferMs: 80) }
        XCTAssertEqual(cooled, [.p1080])
    }

    func testSeriousThermalAt720pStepsDownAndStaysDown() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 2) { $0.next() }
        XCTAssertEqual(run(&ladder, &feed, seconds: 120, thermal: .serious) { $0.next(bufferMs: 80) }, [.p540])
    }

    func testCriticalThermalStepsDownAgainAndCapsAt540p() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 1, thermal: .serious) { $0.next() }
        XCTAssertEqual(ladder.current, .p540)
        _ = run(&ladder, &feed, seconds: 1, thermal: .critical) { $0.next() }
        XCTAssertEqual(ladder.current, .p360)
        XCTAssertEqual(ladder.cap, .p540)
        XCTAssertEqual(run(&ladder, &feed, seconds: 120, thermal: .critical) { $0.next(bufferMs: 80) }, [], "no step up while hot")
    }

    func testDisconnectResumesOneBelowLastStableAndKeepsWalkingDown() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 21) { $0.next(bufferMs: 80) }
        _ = run(&ladder, &feed, seconds: 6) { $0.next(bufferMs: 80) }
        XCTAssertEqual(ladder.lastStable, .p1080)
        XCTAssertEqual(ladder.connectionLost(at: feed.time), .p720)
        // A reconnect that fails before proving stable keeps walking down.
        XCTAssertEqual(ladder.connectionLost(at: feed.time + 1), .p540)
        XCTAssertEqual(ladder.connectionLost(at: feed.time + 2), .p360)
        XCTAssertEqual(ladder.connectionLost(at: feed.time + 3), .p360)
    }

    func testDisconnectAfterPressureStepUsesTheLowerRung() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 6) { $0.next() }
        XCTAssertEqual(ladder.lastStable, .p720)
        _ = run(&ladder, &feed, seconds: 3.5) { $0.next(bufferMs: 1500) }
        XCTAssertEqual(ladder.current, .p540)
        XCTAssertEqual(ladder.connectionLost(at: feed.time), .p360)
    }

    func testReconnectedStreamWithResetCountersIsNotMisreadAsPressure() {
        var ladder = QualityLadder()
        var feed = Feed()
        _ = run(&ladder, &feed, seconds: 5) { $0.next(drops: 0) }
        feed.sent = 0; feed.retransmitted = 0; feed.dropped = 0
        XCTAssertEqual(run(&ladder, &feed, seconds: 10) { $0.next() }, [])
        XCTAssertEqual(ladder.current, .p720)
    }

    func testReconnectBackoffIsOneTwoFourEightThenTenSeconds() {
        XCTAssertEqual((1...7).map { StreamReconnectBackoff.delay(afterFailures: $0) }, [1, 2, 4, 8, 10, 10, 10])
        XCTAssertEqual(StreamReconnectBackoff.delay(afterFailures: 0), 0)
    }
}
