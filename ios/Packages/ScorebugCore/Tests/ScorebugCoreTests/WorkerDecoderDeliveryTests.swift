import Foundation
import XCTest
@testable import ScorebugCore

final class WorkerDecoderDeliveryTests: XCTestCase {
    let expected = UUID(uuidString: "30000000-0000-0000-0000-00000000000c")!
    func fixture(_ n: Int64 = 3, after: Int64? = nil) throws -> WorkerMediaStatusResponse {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-cadence-v1", withExtension: "json", subdirectory: "Fixtures"))
        var r = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: Data(contentsOf: url))
        r.status.observation?.decoderDelivery = try DecoderDeliveryPacketTests.packet(n, after: after)
        r.status.decoderDeliveryAgeUpperBoundMs = 50
        return r
    }
    func testScopedHistoryAndFreshnessIncludeRequestAndLocalResidence() throws {
        var tracker = WorkerDecoderDeliveryTracker(); let now = ContinuousClock.now
        let first = try XCTUnwrap(tracker.observe(response: fixture(), expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .milliseconds(200)))
        XCTAssertEqual(first.sampleAgeUpperBound(at: now), .milliseconds(250))
        XCTAssertEqual(first.sampleAgeUpperBound(at: now + .milliseconds(100)), .milliseconds(350))
        XCTAssertNil(first.sampleAgeUpperBound(at: now - .nanoseconds(1)))
        XCTAssertNil(first.sampleAgeUpperBound(at: now + .seconds(5)))
        XCTAssertEqual(tracker.cursor?.lastOrdinal, 3)
        let next = try XCTUnwrap(tracker.observe(response: fixture(6, after: 3), expectedPublishingAttemptID: expected, receivedAt: now + .milliseconds(100), requestDuration: .zero))
        XCTAssertEqual(next.snapshot.arrivals.count, 6); XCTAssertEqual(tracker.cursor?.lastOrdinal, 6)
        tracker.expire(at: now + .seconds(6)); XCTAssertNil(tracker.latest)
    }
    func testFrozenSamplesCannotBeRejuvenatedAndOmissionRequiresFullResynchronization() throws {
        var tracker = WorkerDecoderDeliveryTracker(); let now = ContinuousClock.now
        XCTAssertNotNil(tracker.observe(response: try fixture(), expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        var repeatSample = try fixture(); repeatSample.status.decoderDeliveryAgeUpperBoundMs = 0
        let repeated = try XCTUnwrap(tracker.observe(response: repeatSample, expectedPublishingAttemptID: expected, receivedAt: now + .seconds(1), requestDuration: .zero))
        XCTAssertEqual(repeated.sampleAgeUpperBound(at: now + .seconds(1)), .milliseconds(1050))
        var missing = repeatSample; missing.status.observation?.decoderDelivery = nil
        XCTAssertNil(tracker.observe(response: missing, expectedPublishingAttemptID: expected, receivedAt: now + .seconds(2), requestDuration: .zero))
        XCTAssertNil(tracker.cursor)
        XCTAssertNil(tracker.observe(response: repeatSample, expectedPublishingAttemptID: expected, receivedAt: now + .seconds(2), requestDuration: .zero))
        XCTAssertNotNil(tracker.observe(response: try fixture(6), expectedPublishingAttemptID: expected, receivedAt: now + .seconds(2), requestDuration: .zero))
    }
    func testEpochChangeRequiresFullBaseAndRetiredBindingCannotReturn() throws {
        var tracker = WorkerDecoderDeliveryTracker(); let now = ContinuousClock.now
        let old = try fixture(); XCTAssertNotNil(tracker.observe(response: old, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        var next = try fixture(6, after: 3); next.status.workerEpoch = "22222222-2222-4222-8222-222222222222"
        XCTAssertNil(tracker.observe(response: next, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero)); XCTAssertNil(tracker.cursor)
        next.status.observation?.decoderDelivery = try DecoderDeliveryPacketTests.packet(6)
        XCTAssertNotNil(tracker.observe(response: next, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        XCTAssertNil(tracker.observe(response: old, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        next.status.observation?.decoderDelivery = try DecoderDeliveryPacketTests.packet(9)
        XCTAssertNotNil(tracker.observe(response: next, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero), "A retired reply must not permanently block current reports")
    }
    func testMalformedMissingPublicationAndUnprovenAgeRemainUnknown() throws {
        let now = ContinuousClock.now
        for fault in 0..<9 {
            var r = try fixture(); var t = WorkerDecoderDeliveryTracker()
            switch fault {
            case 0:r.status.publication = nil
            case 1:r.status.publication?.publishingAttemptId = UUID().uuidString.lowercased()
            case 2:r.status.decoderDeliveryAgeUpperBoundMs = nil
            case 3:r.status.decoderDeliveryAgeUpperBoundMs = .infinity
            case 4:r.status.decoderDeliveryAgeUpperBoundMs = -1
            case 5:r.status.decoderDeliveryAgeUpperBoundMs = 0.5
            case 6:r.status.state = .stale
            case 7:r.status.observation?.decoderDelivery?.ended = true
            default:r.status.observation?.decodedVideo?.clock = nil
            }
            XCTAssertNil(t.observe(response:r,expectedPublishingAttemptID:expected,receivedAt:now,requestDuration:.zero))
        }
        for duration: Duration in [.nanoseconds(-1), .seconds(6), .seconds(Int64.max)] {
            var t = WorkerDecoderDeliveryTracker()
            XCTAssertNil(t.observe(response:try fixture(),expectedPublishingAttemptID:expected,receivedAt:now,requestDuration:duration))
        }
    }
    func testUnprovenSampleCannotAcquireAProofRetroactively() throws {
        let now = ContinuousClock.now; var tracker = WorkerDecoderDeliveryTracker()
        var response = try fixture(); response.status.decoderDeliveryAgeUpperBoundMs = nil
        XCTAssertNil(tracker.observe(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        response.status.decoderDeliveryAgeUpperBoundMs = 0
        XCTAssertNil(tracker.observe(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
        response.status.observation?.decoderDelivery = try DecoderDeliveryPacketTests.packet(6)
        XCTAssertNotNil(tracker.observe(response: response, expectedPublishingAttemptID: expected, receivedAt: now, requestDuration: .zero))
    }
    func testActualPacketsThroughHTTPClientWithExplicitFixturePublicationAndEpochResync() async throws {
        struct Replay: Decodable {
            let sourceRows: [DecoderDeliveryPacket.Arrival]
            let packets: [DecoderDeliveryPacket]
            let epochs: [String]
            let sampleAgeUpperBoundsMs: [Double]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource:"decoder-delivery-replay-v1",withExtension:"json",subdirectory:"Fixtures"))
        let replay = try JSONDecoder().decode(Replay.self,from:Data(contentsOf:url))
        var tracker = WorkerDecoderDeliveryTracker(); let start = ContinuousClock.now
        let credential = MatchCredential(gameId:"match",deviceId:"phone",role:.capture,token:"fixture-only")
        var accepted = 0, missingBase = 0
        for (index, rawPacket) in replay.packets.enumerated() {
            var response = try fixture()
            response.status.workerEpoch = replay.epochs[index]
            response.status.decoderDeliveryAgeUpperBoundMs = replay.sampleAgeUpperBoundsMs[index]
            // The trace has no physical publication binding. Use fixture identity
            // and synthesize a full resync reply when this native client requests it.
            var packet = rawPacket
            if tracker.cursor == nil {
                packet.afterOrdinal = packet.retainedBase
                packet.arrivals = Array(replay.sourceRows[Int(packet.afterOrdinal)..<Int(packet.lastOrdinal)])
            }
            response.status.observation?.decoderDelivery = packet
            let data = try JSONEncoder().encode(response)
            let client = MatchHTTPClient(endpoint:try ScoringEndpoint("https://example.com"),transport:{request in
                return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            let status = try await client.workerStatus(credential:credential,delivery:tracker.cursor.map(DecoderDeliveryRequest.after) ?? .full)
            let now = start + .milliseconds(index * 100)
            if let value = tracker.observe(response:status,expectedPublishingAttemptID:expected,receivedAt:now,requestDuration:.milliseconds(1)) {
                accepted += 1
                XCTAssertEqual(value.context.workerEpoch,replay.epochs[index])
                XCTAssertEqual(value.snapshot.arrivals.map(\.pts),Array(replay.sourceRows[Int(packet.retainedBase)..<Int(packet.lastOrdinal)]).map(\.pts))
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(value.sampleAgeUpperBound(at:now)),.milliseconds(Int64(replay.sampleAgeUpperBoundsMs[index])+1))
            } else { missingBase += 1; XCTAssertNil(tracker.cursor) }
        }
        XCTAssertEqual(accepted,160);XCTAssertEqual(missingBase,1)
        XCTAssertEqual(tracker.latest?.snapshot.lastOrdinal,478)
    }
    func testMalformedAdditivePacketDoesNotBreakOrdinaryWorkerStatus() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        var status = object["status"] as! [String: Any]; var observation = status["observation"] as! [String: Any]
        observation["decoderDelivery"] = ["formatVersion": "bad"]; status["observation"] = observation
        status["decoderDeliveryAgeUpperBoundMs"] = "bad"; object["status"] = status
        let decoded = try JSONDecoder().decode(WorkerMediaStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.status.state, .producingOutput); XCTAssertNil(decoded.status.observation?.decoderDelivery)
        XCTAssertNil(decoded.status.decoderDeliveryAgeUpperBoundMs)
    }
    func testRequestTimingAnchorsSampleAndClampsToClockOrigin() throws {
        let now = ContinuousClock.now
        for start in [100.0, 0.02] {
            var tracker = WorkerDecoderDeliveryTracker()
            let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: start, receivedAt: start + 0.2))
            let proof = try XCTUnwrap(tracker.observe(response: fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: .milliseconds(200), requestTiming: timing))
            let bounds = try XCTUnwrap(proof.sampleTimeBounds)
            XCTAssertEqual(bounds.lower, max(0, start - 0.05), accuracy: 1e-9)
            XCTAssertEqual(bounds.upper, start + 0.2)
            XCTAssertEqual(proof.sampleAgeUpperBound(at: now), .milliseconds(250))
        }
    }
    func testFrozenSampleRetainsExactAnchorIncludingNilAndGetsNewReceipt() throws {
        let now = ContinuousClock.now
        for anchored in [false, true] {
            var tracker = WorkerDecoderDeliveryTracker()
            let initialTiming = anchored ? DeliveryRequestTiming(startedAt: 100, receivedAt: 100.2) : nil
            let first = try XCTUnwrap(tracker.observe(response: fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: .milliseconds(200), requestTiming: initialTiming))
            var frozen = try fixture(); frozen.status.decoderDeliveryAgeUpperBoundMs = 0
            let repeated = try XCTUnwrap(tracker.observe(response: frozen, expectedPublishingAttemptID: expected,
                receivedAt: now + .seconds(1), requestDuration: .milliseconds(200),
                requestTiming: DeliveryRequestTiming(startedAt: 101, receivedAt: 101.2)))
            XCTAssertEqual(repeated.sampleTimeBounds, first.sampleTimeBounds)
            XCTAssertNotEqual(repeated.receiptID, first.receiptID)
            XCTAssertEqual(repeated.sampleAgeUpperBound(at: now + .seconds(1)), .milliseconds(1250))
            let omittedTiming = try XCTUnwrap(tracker.observe(response: frozen, expectedPublishingAttemptID: expected,
                receivedAt: now + .seconds(2), requestDuration: .zero))
            XCTAssertEqual(omittedTiming.sampleTimeBounds, first.sampleTimeBounds)
            XCTAssertNotEqual(omittedTiming.receiptID, repeated.receiptID)
            let freshWithoutTiming = try XCTUnwrap(tracker.observe(response: fixture(6), expectedPublishingAttemptID: expected,
                receivedAt: now + .seconds(2), requestDuration: .zero))
            XCTAssertNil(freshWithoutTiming.sampleTimeBounds)
        }
    }
    func testRequestClockReversalIsRejectedAcrossOmissionAndUnavailable() throws {
        let now = ContinuousClock.now
        for timing in [DeliveryRequestTiming(startedAt: 99.9, receivedAt: 101)!,
                       DeliveryRequestTiming(startedAt: 100.1, receivedAt: 100.15)!] {
            var tracker = WorkerDecoderDeliveryTracker()
            XCTAssertNotNil(tracker.observe(response: try fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: .milliseconds(200),
                requestTiming: DeliveryRequestTiming(startedAt: 100, receivedAt: 100.2)))
            XCTAssertNotNil(tracker.observe(response: try fixture(6), expectedPublishingAttemptID: expected,
                receivedAt: now + .milliseconds(100), requestDuration: .zero))
            tracker.unavailable()
            XCTAssertNil(tracker.observe(response: try fixture(9), expectedPublishingAttemptID: expected,
                receivedAt: now + .milliseconds(200), requestDuration: .zero, requestTiming: timing))
            XCTAssertNil(tracker.latest); XCTAssertNil(tracker.cursor)
            XCTAssertNotNil(tracker.observe(response: try fixture(12), expectedPublishingAttemptID: expected,
                receivedAt: now + .milliseconds(300), requestDuration: .zero,
                requestTiming: DeliveryRequestTiming(startedAt: 101, receivedAt: 101.2)))
            tracker.reset()
            XCTAssertNotNil(tracker.observe(response: try fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: .zero, requestTiming: timing))
        }
    }

    func testRequestTimingMustEncloseSeparatelyMeasuredRequestDuration() throws {
        let now = ContinuousClock.now
        for (start, receipt) in [(10.0, 10.0), (10.0, 10.199), (10.0, 10.199999)] {
            var tracker = WorkerDecoderDeliveryTracker()
            let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: start, receivedAt: receipt))
            XCTAssertNil(tracker.observe(response: try fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: .milliseconds(200), requestTiming: timing),
                "The uptime bracket must enclose the full ContinuousClock request duration")
            XCTAssertNil(tracker.latest)
        }
    }
    func testPairedRequestTimingAcceptsEnclosureAndSubtractionRoundoff() throws {
        let now = ContinuousClock.now
        let cases: [(Double, Double, Duration)] = [
            (10, 10, .zero), (10, 10.25, .milliseconds(250)),
            (10, 10.3, .milliseconds(200)), (10, 10.2, .milliseconds(200)),
            (10, 11.2, .seconds(1) + .milliseconds(200)),
            (1e12 - 0.2, 1e12, .milliseconds(200))
        ]
        for (start, receipt, duration) in cases {
            var tracker = WorkerDecoderDeliveryTracker()
            let timing = try XCTUnwrap(DeliveryRequestTiming(startedAt: start, receivedAt: receipt))
            XCTAssertNotNil(tracker.observe(response: try fixture(), expectedPublishingAttemptID: expected,
                receivedAt: now, requestDuration: duration, requestTiming: timing),
                "Exact durations and subtraction-level representation error remain valid")
        }
    }

}
