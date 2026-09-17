import Foundation
import AVFoundation
import ScorebugMedia
@testable import ScorebugStreaming
@testable import HaishinKit
@testable import SRTHaishinKit
import XCTest

final class NativeCandidateFixtureTests: XCTestCase {
    func testCombinedHeadroomRouteRequiresExactCompleteOptInInBothParsers() throws {
        let valid = ["SCOREBUG_TEST_CANDIDATE_HEADROOM": "1", "SCOREBUG_TEST_CANDIDATE_PROFILE": "540p30",
            "SCOREBUG_TEST_BANDWIDTH_PROBE": "staged", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        for profile in ["360p30", "540p30", "1080p30"] {
            var environment = valid; environment["SCOREBUG_TEST_CANDIDATE_PROFILE"] = profile
            XCTAssertEqual(try NativeCandidateFixture.requested(environment: environment)?.rawValue, profile)
            XCTAssertEqual(try NativeBandwidthProbePublisher.requested(environment: environment), .staged)
        }
        for (key, value) in [("SCOREBUG_TEST_CANDIDATE_HEADROOM", ""), ("SCOREBUG_TEST_CANDIDATE_HEADROOM", "true"),
            ("SCOREBUG_TEST_CANDIDATE_PROFILE", ""), ("SCOREBUG_TEST_BANDWIDTH_PROBE", "renew"),
            ("SCOREBUG_TEST_LIVE_PROFILE", "540p30"), ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", "0"),
            ("SCOREBUG_TEST_MOTION_FIXTURE", "blocks"), ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"),
            ("SCOREBUG_TEST_NATIVE_QUALITY", "1"), ("SCOREBUG_TEST_NATIVE_CONFIRMATION", "1"),
            ("SCOREBUG_TEST_ADAPTIVE_PROFILES", "1"), ("SCOREBUG_TEST_PROFILE_TRANSITIONS", "1"),
            ("SCOREBUG_TEST_SOURCE_CADENCE_PACING", "1"), ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "1234"),
            ("SCOREBUG_TEST_DECODER_STALL", "reset540")] {
            var bad = valid; bad[key] = value
            XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: bad), "\(key)=\(value)")
            XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: bad), "\(key)=\(value)")
        }
        for environment in [["SCOREBUG_TEST_CANDIDATE_HEADROOM": "1"], ["SCOREBUG_TEST_CANDIDATE_HEADROOM": ""]] {
            XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: environment))
            XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: environment))
        }
        for key in ["SCOREBUG_TEST_CANDIDATE_PROFILE", "SCOREBUG_TEST_BANDWIDTH_PROBE"] {
            var orphan = valid; orphan.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: orphan))
            XCTAssertThrowsError(try NativeBandwidthProbePublisher.requested(environment: orphan))
        }
    }

    @MainActor func testSerializationPreservesActualRawBytesAndAdmissionTime() async throws {
        let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low360)
        try await candidate.start()
        let sample = try candidateVideo().sampleBuffer
        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(candidate.offer(sample))
        let after = ProcessInfo.processInfo.systemUptime
        let result = await candidate.finish()
        XCTAssertEqual(result.encoding.outcome, .completed)
        let measurement = PublishingCandidateMeasurement.Result(id: candidate.id, scope: scope, profile: .low360,
            reason: .completed, startedAt: before, endedAt: ProcessInfo.processInfo.systemUptime,
            acceptedInputCount: 1, firstInputPTS: sample.presentationTimeStamp,
            lastInputPTS: sample.presentationTimeStamp, encoding: result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: NativeCandidateFixture.data(measurement)) as? [String: Any])
        let encoding = try XCTUnwrap(object["encoding"] as? [String: Any])
        let frames = try XCTUnwrap(encoding["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame["rawByteCount"] as? Int, CVPixelBufferGetDataSize(try XCTUnwrap(sample.imageBuffer)))
        let admitted = try XCTUnwrap(frame["admittedAt"] as? Double)
        XCTAssertGreaterThanOrEqual(admitted, before)
        XCTAssertLessThanOrEqual(admitted, after)
    }

    @MainActor func testSerializationPreservesCompleteAudioWindowAndOrderedMuxReceipts() async throws {
        let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let transport = PublishingCandidateTransport(scope: scope, profile: .low360)
        let candidate = try PublishingCandidateEncoder(scope: scope, profile: .low360, transport: transport)
        XCTAssertTrue(transport.arm(publishingGeneration: 7))
        try await candidate.start()
        let sample = try candidateVideo(at: CMTime(value: 10, timescale: 1)).sampleBuffer
        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(candidate.offer(sample))
        for index in 0...1 {
            let host = AVAudioTime.hostTime(forSeconds: 10 + Double(index) * 1024 / 48000)
            let audioPTS = CMTime(seconds: AVAudioTime.seconds(forHostTime: host), preferredTimescale: 1_000_000_000)
            transport.observeAudio(PublishingCandidateTransport.AudioSnapshot(sourcePTS: audioPTS, hostTime: host,
                publishingGeneration: 7, wasEncoded: true, valid: true, observedAt: ProcessInfo.processInfo.systemUptime,
                sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2,
                payload: Data([1, 2, 3, 4])))
        }
        let result = await candidate.finish()
        XCTAssertEqual(result.transport?.outcome, .completed, result.transport?.failure ?? "")
        let measurement = PublishingCandidateMeasurement.Result(id: candidate.id, scope: scope, profile: .low360,
            reason: .completed, startedAt: before, endedAt: ProcessInfo.processInfo.systemUptime,
            acceptedInputCount: 1, firstInputPTS: sample.presentationTimeStamp,
            lastInputPTS: sample.presentationTimeStamp, encoding: result)
        let data = NativeCandidateFixture.data(measurement)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let window = try XCTUnwrap(object["transport"] as? [String: Any])
        XCTAssertEqual(window["id"] as? String, candidate.id.uuidString)
        XCTAssertEqual(window["publishingGeneration"] as? String, "7")
        XCTAssertEqual(window["outcome"] as? String, "completed")
        let audio = try XCTUnwrap(window["audio"] as? [[String: Any]])
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(audio.first?["byteCount"] as? Int, 4)
        XCTAssertEqual(audio.first?["wasEncoded"] as? Bool, true)
        XCTAssertNil(audio.first?["payload"])
        XCTAssertNotNil(window["followingAudio"] as? [String: Any])
        let mux = try XCTUnwrap(window["mux"] as? [String: Any])
        let inputs = try XCTUnwrap(mux["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(Set(inputs.compactMap { $0["media"] as? String }), Set(["video", "audio"]))
        XCTAssertGreaterThan(try XCTUnwrap(mux["transportBytes"] as? Int), 4)
        XCTAssertLessThan(data.count, 256 * 1024)
    }

    func testFlagsRequireExclusiveHigherCandidateAndFullFixedProfileFixture() throws {
        let valid = ["SCOREBUG_TEST_CANDIDATE_PROFILE": "540p30", "SCOREBUG_TEST_VIDEO_OBSERVATIONS": "1",
            "SCOREBUG_TEST_LIVE_PROFILE": "240p30", "SCOREBUG_TEST_MOTION_FIXTURE": "blocks16",
            "SCOREBUG_TEST_STREAM_HOLD_SECONDS": "90"]
        XCTAssertEqual(try NativeCandidateFixture.requested(environment: valid), .sd540)
        XCTAssertNil(try NativeCandidateFixture.requested(environment: [:]))
        for (key, value) in [("SCOREBUG_TEST_CANDIDATE_PROFILE", "240p30"), ("SCOREBUG_TEST_CANDIDATE_PROFILE", ""),
            ("SCOREBUG_TEST_CANDIDATE_PROFILE", "bogus"), ("SCOREBUG_TEST_VIDEO_OBSERVATIONS", ""),
            ("SCOREBUG_TEST_STREAM_HOLD_SECONDS", "89"), ("SCOREBUG_TEST_NATIVE_QUALITY", "1"),
            ("SCOREBUG_TEST_ADAPTIVE_PROFILES", "1"), ("SCOREBUG_TEST_PROFILE_TRANSITIONS", "1"),
            ("SCOREBUG_TEST_BANDWIDTH_PROBE", "staged"), ("SCOREBUG_TEST_SOURCE_CADENCE_PACING", "1"),
            ("SCOREBUG_TEST_UPLINK_PROXY_PORT", "1234"), ("SCOREBUG_TEST_DECODER_STALL", "reset540")] {
            var bad = valid; bad[key] = value
            XCTAssertThrowsError(try NativeCandidateFixture.requested(environment: bad), "\(key)=\(value)")
        }
    }
}

extension NativeCandidateFixtureTests {
    func testReturnedTypedSnapshotAuthorityRevokesAfterPressureOwnerChangeAndStop() async throws {
        for fault in 0..<4 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
            fake.produceTypedCost = true; fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            fake.finish(); await wrapper.waitForMeasurement()
            let joined = await wrapper.candidateSnapshot()
            let snapshot = try XCTUnwrap(joined)
            XCTAssertTrue(snapshot.permitsCurrentCandidate(snapshot.cost.id))
            XCTAssertFalse(snapshot.permitsCurrentCandidate(UUID()))
            switch fault {
            case 0:
                fake.setFault(0)
                _ = await wrapper.candidateSnapshot()
            case 1: _ = try? await wrapper.setVideoBitRate(123)
            case 2: _ = try? await wrapper.setVideoProfile(.low360)
            default: await wrapper.stop()
            }
            XCTAssertFalse(snapshot.permitsCurrentCandidate(snapshot.cost.id), "fault \(fault)")
            await wrapper.stop()
            XCTAssertFalse(snapshot.permitsCurrentCandidate(snapshot.cost.id))
        }
    }
    func testTypedSnapshotRequiresJoinAndPreservesPinnedAndFreshProbeEvidence() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
        fake.produceTypedCost = true; fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        let beforeJoin = await wrapper.candidateSnapshot()
        XCTAssertNil(beforeJoin)
        fake.finish(); await wrapper.waitForMeasurement()
        let joined = await wrapper.candidateSnapshot()
        let initial = try XCTUnwrap(joined)
        XCTAssertEqual(initial.cost.scope, fake.scope)
        XCTAssertEqual(initial.cost.transportBytes, 376000)
        XCTAssertEqual(initial.binding.id, initial.probe.id)
        XCTAssertEqual(initial.binding.acceptedPayloadBytes, 1316)
        XCTAssertLessThanOrEqual(initial.boundAt, initial.cost.startedAt)
        XCTAssertGreaterThanOrEqual(initial.completedAt, initial.cost.endedAt)
        fake.advanceProbeReceipt()
        let refreshed = await wrapper.candidateSnapshot()
        let current = try XCTUnwrap(refreshed)
        XCTAssertEqual(current.cost.id, initial.cost.id)
        XCTAssertEqual(current.binding.acceptedPayloadBytes, 1316)
        XCTAssertEqual(current.probe.acceptedPayloadBytes, 2632)
        XCTAssertEqual(current.completedAt, initial.completedAt)
        await wrapper.stop()
        let stopped = await wrapper.candidateSnapshot()
        XCTAssertNil(stopped)
        let binding = try XCTUnwrap(fake.object?["probeBinding"] as? [String: Any])
        let final = try XCTUnwrap(binding["final"] as? [String: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(final["observedAt"] as? Double), initial.completedAt)
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testTypedSnapshotRejectsMissingCostPressureChangeAndRetiredCurrentProbe() async throws {
        for fault in 0..<10 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
            fake.produceTypedCost = fault != 0; fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            fake.finish(); await wrapper.waitForMeasurement()
            if fault == 1 { fake.setFault(0) }
            else if fault >= 2 { fake.mutateProbe(fault - 2) }
            let snapshot = await wrapper.candidateSnapshot()
            XCTAssertNil(snapshot, "fault \(fault)")
            await wrapper.stop()
        }
    }
    func testTypedSnapshotRejectsWrongScopeGenerationStaleAndFutureCost() async throws {
        for fault in 0..<4 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
            fake.produceTypedCost = true; fake.typedCostFault = fault; fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            fake.finish(); await wrapper.waitForMeasurement()
            XCTAssertNotNil(fake.producedCost, "fault \(fault) must still produce internally valid cost")
            let snapshot = await wrapper.candidateSnapshot()
            XCTAssertNil(snapshot, "fault \(fault)")
            await wrapper.stop()
        }
    }
    func testTypedSnapshotRechecksRevocationAfterSuspendedProbeRead() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
        fake.produceTypedCost = true; fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement()
        fake.blockNextProbeRead()
        let read = Task { await wrapper.candidateSnapshot() }
        await wait { fake.probeReadIsBlocked }
        _ = try? await wrapper.setVideoBitRate(123)
        fake.releaseProbeRead()
        let snapshot = await read.value
        XCTAssertNil(snapshot)
        await wrapper.stop()
    }
    func testOneMatchingBootstrapWriteBeforeCandidateStartPreservesMeasurement() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
        fake.allowBitRateWrite = true; fake.setProbe(stage: 2)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        await wait { fake.probeReads > 0 }
        _ = try await wrapper.setVideoBitRate(PublishingVideoProfile.low240.bitRate)
        XCTAssertFalse(fake.reasons.contains(.ownerChanged))
        fake.setProbe(stage: 3)
        await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testSecondBootstrapWriteAndWriteCrossingCandidateStartRevoke() async throws {
        for crossingStart in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
            fake.allowBitRateWrite = true; fake.setProbe(stage: 2)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.probeReads > 0 }
            if crossingStart {
                fake.blockBitRateWrite = true
                let write = Task { try await wrapper.setVideoBitRate(PublishingVideoProfile.low240.bitRate) }
                await wait { fake.events.contains("bitRate") }
                fake.setProbe(stage: 3)
                await wait { fake.waiting }
                fake.releaseBitRateWrite()
                _ = try? await write.value
            } else {
                _ = try await wrapper.setVideoBitRate(PublishingVideoProfile.low240.bitRate)
                _ = try await wrapper.setVideoBitRate(PublishingVideoProfile.low240.bitRate)
            }
            XCTAssertTrue(fake.reasons.contains(.ownerChanged))
            await wrapper.stop()
        }
    }
    func testPrimaryAppendPrecedesOptionalVideoAndStopJoinsOnce() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        await wait { fake.waiting }
        try await wrapper.append(candidateVideo())
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        fake.finish()
        await wrapper.waitForMeasurement()
        XCTAssertEqual(fake.exports, 0)
        async let one: Void = wrapper.stop()
        async let two: Void = wrapper.stop()
        _ = await (one, two)
        XCTAssertEqual(fake.stops, 1); XCTAssertEqual(fake.exports, 1)
        XCTAssertEqual(fake.object?["invalidReason"] is NSNull, true)
        XCTAssertEqual(fake.object?["formatVersion"] as? Int, 3)
        XCTAssertEqual(fake.object?["resourceLimits"] as? [String: Int],
            ["rawQueueCount": 4, "unresolvedInputCount": 16, "unresolvedRawBytes": 64 * 1024 * 1024,
             "rawBytesPerInput": 16 * 1024 * 1024])
    }
    func testNewDropsStaleThermalAndMissingDiagnosticsRevokeOptionalOnly() async throws {
        for fault in 0..<5 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start()
            await wait { fake.waiting }
            fake.setFault(fault)
            try await wrapper.append(candidateVideo())
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertTrue(fake.reasons.contains(.pressure))
            XCTAssertEqual(fake.stops, 0)
            await wrapper.stop()
            XCTAssertEqual(fake.object?["invalidReason"] as? String, "pressure")
        }
    }
    func testPrimaryFailureAndEncoderMutationRevokeWithoutWaitingForCandidateJoin() async throws {
        for mutation in 0..<3 {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            do {
                if mutation == 0 { fake.failAppend = true; try await wrapper.append(candidateVideo()) }
                if mutation == 1 { _ = try await wrapper.setVideoBitRate(123) }
                if mutation == 2 { _ = try await wrapper.setVideoProfile(.low360) }
                XCTFail("primary fake throws")
            } catch {}
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertEqual(fake.reasons.first, mutation == 0 ? .pressure : .ownerChanged)
            XCTAssertEqual(fake.stops, 0)
            await wrapper.stop()
        }
    }
    func testStopBeforeDelayNeverStartsCandidateAndMissingDiagnosticsCannotStart() async throws {
        for missing in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, delay: missing ? .zero : .seconds(20))
            if !missing { await wrapper.setDiagnostics { fake.pressure } }
            try await wrapper.start()
            if missing { await wait { !fake.reasons.isEmpty } }
            await wrapper.stop()
            XCTAssertFalse(fake.events.contains("candidateStart")); XCTAssertEqual(fake.exports, 1)
            XCTAssertNotNil(fake.object?["invalidReason"] as? String)
        }
    }
    func testMutationAfterMeasurementCannotExportCurrentOwnerProof() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement()
        _ = try? await wrapper.setVideoProfile(.low360)
        await wrapper.stop()
        XCTAssertEqual(fake.object?["invalidReason"] as? String, "ownerChanged")
    }
    func testPressureMonitorRevokesWithoutAnotherFrame() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.setFault(1)
        await wait { fake.reasons.contains(.pressure) }
        XCTAssertEqual(fake.stops, 0)
        await wrapper.stop()
    }
    func testFrameAlreadyInsidePrimaryCannotBecomeCandidateAfterDelayedStart() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, delay: .milliseconds(50))
        fake.blockAppend = true
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        let append = Task { try await wrapper.append(candidateVideo()) }
        await wait { fake.events.contains("primary") }
        await wait { fake.waiting }
        fake.releaseAppend()
        try await append.value
        XCTAssertFalse(fake.events.contains("candidate"))
        await wrapper.stop()
    }
    func testStopJoinsDelayedPrimaryStartupBeforeExportingClosedEvidence() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        fake.blockStart = true
        await wrapper.setDiagnostics { fake.pressure }
        let startup = Task { try await wrapper.start() }
        await wait { fake.events.contains("primaryStart") }
        let stop = Task { await wrapper.stop() }
        await wait { fake.stops > 0 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fake.exports, 0, "closed evidence must await the primary startup join")
        fake.releaseStart()
        await stop.value
        do { try await startup.value; XCTFail("stopped startup cannot succeed") } catch {}
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(fake.exports, 1)
        XCTAssertFalse(fake.events.contains("candidateStart"))
    }
    func testCombinedCompositionPreservesStartupPrimaryAppendAndProbeObservation() async throws {
        let fake = CandidateFixtureFake()
        fake.setProbe(stage: 3)
        let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let probe = NativeBandwidthProbePublisher(publisher: fake, scope: scope, mode: .staged,
            operations: .init(clock: { nil }, begin: { throw PublishingSessionError.invalidState },
                renew: { _,_ in throw PublishingSessionError.invalidState }, cancel: { _,_ in },
                snapshot: {
                    guard let value = await fake.probeObservation() else { return nil }
                    return NativeBandwidthProbeSample(id: value.id, publishingGeneration: value.publishingGeneration,
                        bitRate: value.bitRate, startedAt: value.startedAt, leaseDeadline: value.leaseDeadline,
                        acceptedPayloadBytes: value.acceptedPayloadBytes, lastAcceptedAt: value.lastAcceptedAt,
                        reason: value.reason, stage: value.stage, permitsCurrentOwner: value.permitsCurrentOwner)
                }, export: { _ in }), timing: .init(delay: .seconds(20)), candidateHeadroom: true)
        let wrapper = NativeCandidatePublisher(publisher: probe, scope: scope, liveProfile: .low240,
            operations: fake.operations, timing: .init(delay: .zero, poll: .milliseconds(10)), candidateHeadroom: true)
        XCTAssertEqual(wrapper.videoStartup, fake.videoStartup)
        let forwarded = await wrapper.probeObservation(), source = await fake.probeObservation()
        XCTAssertEqual(forwarded?.id, source?.id)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        try await wrapper.append(candidateVideo())
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        XCTAssertEqual(fake.exports, 1); XCTAssertEqual(fake.stops, 1)
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testCombinedRefreshesLeaseAfterCandidateStartupJoin() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
        fake.setProbe(stage: 3); fake.blockCandidateStart = true
        fake.updateProbeLease(after: 0.05)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.events.contains("candidateStart") }
        try await Task.sleep(for: .milliseconds(60))
        fake.updateProbeLease(after: 10)
        fake.releaseCandidateStart()
        await wait { fake.waiting }
        try await wrapper.append(candidateVideo())
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testCombinedWaitsForMatureCurrentFinalStageAndExportsBinding() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
        fake.setProbe(stage: 2)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start()
        await wait { fake.probeReads >= 2 }
        XCTAssertFalse(fake.events.contains("candidateStart"))
        fake.setProbe(stage: 3, age: 0)
        let reads = fake.probeReads
        await wait { fake.probeReads >= reads + 2 }
        XCTAssertFalse(fake.events.contains("candidateStart"))
        fake.setProbe(stage: 3)
        await wait { fake.waiting }
        let observation = await wrapper.probeObservation()
        let bound = try XCTUnwrap(observation)
        try await wrapper.append(candidateVideo())
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        let binding = try XCTUnwrap(fake.object?["probeBinding"] as? [String: Any])
        let initial = try XCTUnwrap(binding["initial"] as? [String: Any])
        let final = try XCTUnwrap(binding["final"] as? [String: Any])
        XCTAssertEqual(initial["id"] as? String, bound.id.uuidString)
        XCTAssertEqual(final["id"] as? String, bound.id.uuidString)
        XCTAssertEqual(initial["stage"] as? Int, 3)
        XCTAssertEqual(initial["bitRate"] as? Int, 12_000_000)
        XCTAssertEqual(initial["publishingGeneration"] as? String, "7")
        XCTAssertNotNil(initial["observedAt"] as? Double)
        XCTAssertNotNil(final["observedAt"] as? Double)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(binding["completedAt"] as? Double), try XCTUnwrap(binding["boundAt"] as? Double))
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testCombinedRejectsMissingRetiredWrongStageAndStaleProbeAtGate() async throws {
        for fault in [0, 1, 2, 3, 4, 5, 7] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, probeWaitPolls: 2)
            fake.setProbe(stage: 3)
            fake.mutateProbe(fault)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start()
            await wait { !fake.reasons.isEmpty }
            XCTAssertFalse(fake.events.contains("candidateStart"), "fault \(fault)")
            await wrapper.stop()
            XCTAssertNotNil(fake.object?["invalidReason"] as? String)
        }
    }
    func testCombinedAppendRevalidatesSnapshotSupersededByMonitor() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
        fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.blockNextProbeRead()
        let append = Task { try await wrapper.append(candidateVideo()) }
        await wait { fake.probeReadIsBlocked }
        fake.advanceProbeReceipt()
        await wait { fake.pressureProbeBytes == 2 * 1316 }
        let readsBeforeRelease = fake.probeReads
        fake.releaseProbeRead()
        try await append.value
        XCTAssertGreaterThan(fake.probeReads, readsBeforeRelease, "a superseded response requires a fresh native read")
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        XCTAssertFalse(fake.reasons.contains(.ownerChanged))
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
        let binding = try XCTUnwrap(fake.object?["probeBinding"] as? [String: Any])
        let final = try XCTUnwrap(binding["final"] as? [String: Any])
        XCTAssertEqual(final["acceptedPayloadBytes"] as? String, "2632")
        XCTAssertLessThanOrEqual(try XCTUnwrap(final["observedAt"] as? Double), try XCTUnwrap(binding["completedAt"] as? Double))
    }
    func testCombinedFreshRegressionStillRevokesWithAndWithoutSupersededRead() async throws {
        for overlap in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
            fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            let append: Task<Void, Error>?
            if overlap {
                fake.blockNextProbeRead()
                append = Task { try await wrapper.append(candidateVideo()) }
                await wait { fake.probeReadIsBlocked }
            } else { append = nil }
            fake.advanceProbeReceipt()
            await wait { fake.pressureProbeBytes == 2 * 1316 }
            fake.regressProbeReceipt()
            if overlap { fake.releaseProbeRead(); try await append?.value }
            else { try await wrapper.append(candidateVideo()) }
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertTrue(fake.reasons.contains(.ownerChanged))
            await wrapper.stop()
            XCTAssertEqual(fake.object?["invalidReason"] as? String, "ownerChanged")
        }
    }
    func testCombinedAppendRefreshesRenewedLeaseBeforeMonitorPoll() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
        fake.setProbe(stage: 3); fake.updateProbeLease(after: 0.2)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        let initial = await fake.probeObservation()
        let deadline = try XCTUnwrap(initial).leaseDeadline
        let readsBefore = fake.probeReads
        while ProcessInfo.processInfo.systemUptime <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        fake.updateProbeLease(after: 10)
        XCTAssertEqual(fake.probeReads, readsBefore, "the monitor has not refreshed the expired cached lease")
        try await wrapper.append(candidateVideo())
        XCTAssertGreaterThan(fake.probeReads, readsBefore)
        XCTAssertEqual(fake.events.suffix(2), ["primary", "candidate"])
        XCTAssertFalse(fake.reasons.contains(.ownerChanged))
        fake.finish(); await wrapper.waitForMeasurement(); await wrapper.stop()
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
    }
    func testCombinedAppendRejectsChangedCurrentIdentityAndRateBeforeMonitorPoll() async throws {
        for fault in [5, 6, 7] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
            fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            let readsBefore = fake.probeReads
            fake.mutateProbe(fault) // The previously pinned authority closure remains true.
            try await wrapper.append(candidateVideo())
            XCTAssertGreaterThan(fake.probeReads, readsBefore)
            XCTAssertEqual(fake.events.last, "primary")
            XCTAssertFalse(fake.events.contains("candidate"))
            XCTAssertTrue(fake.reasons.contains(.ownerChanged))
            await wrapper.stop()
        }
    }
    func testCombinedAppendCannotOfferAfterSampleCompletesOrStopsDuringFreshRead() async throws {
        for stop in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10))
            fake.setProbe(stage: 3)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }
            fake.blockNextProbeRead()
            let append = Task { try await wrapper.append(candidateVideo()) }
            await wait { fake.probeReadIsBlocked }
            if stop { await wrapper.stop() }
            else { fake.finish(); await wrapper.waitForMeasurement() }
            fake.releaseProbeRead()
            try await append.value
            XCTAssertFalse(fake.events.contains("candidate"))
            await wrapper.stop()
            XCTAssertEqual(fake.exports, 1)
            if !stop {
                XCTAssertTrue(fake.object?["invalidReason"] is NSNull)
                let binding = try XCTUnwrap(fake.object?["probeBinding"] as? [String: Any])
                let final = try XCTUnwrap(binding["final"] as? [String: Any])
                XCTAssertLessThanOrEqual(try XCTUnwrap(final["observedAt"] as? Double),
                    try XCTUnwrap(binding["completedAt"] as? Double), "a late append read cannot alter joined final evidence")
            }
        }
    }
    func testCombinedPinnedAuthorityRevocationPreventsNextOffer() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
        fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.mutateProbe(4)
        try await wrapper.append(candidateVideo())
        XCTAssertFalse(fake.events.contains("candidate"))
        XCTAssertTrue(fake.reasons.contains(.ownerChanged))
        await wrapper.stop()
    }
    func testCombinedMonitorAndCompletionRequireFreshSameProbe() async throws {
        for fault in [0, 1, 2, 3, 4, 5, 6, 7] {
            for finish in [false, true] {
                let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
                fake.setProbe(stage: 3)
                await wrapper.setDiagnostics { fake.pressure }
                try await wrapper.start(); await wait { fake.waiting }
                fake.mutateProbe(fault)
                if finish { fake.finish(); await wrapper.waitForMeasurement() }
                else { await wait { fake.reasons.contains(.ownerChanged) } }
                try await wrapper.append(candidateVideo())
                XCTAssertFalse(fake.events.contains("candidate"))
                await wrapper.stop()
                XCTAssertEqual(fake.object?["invalidReason"] as? String, "ownerChanged", "fault \(fault), finish \(finish)")
            }
        }
    }
    func testCombinedStopDuringGateAndSampleJoinsBeforeSingleExport() async throws {
        for sampling in [false, true] {
            let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake, candidateHeadroom: true)
            fake.setProbe(stage: sampling ? 3 : 2)
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start()
            await wait { sampling ? fake.waiting : fake.probeReads > 0 }
            async let first: Void = wrapper.stop()
            async let second: Void = wrapper.stop()
            _ = await (first, second)
            XCTAssertEqual(fake.stops, 1); XCTAssertEqual(fake.exports, 1)
            XCTAssertEqual(fake.object?["invalidReason"] as? String, "publisherStopped")
            XCTAssertEqual(fake.events.contains("candidateStart"), sampling)
        }
    }
    func testStopJoinsSuspendedNativeProfileWriteBeforeExport() async throws {
        let fake = CandidateFixtureFake(), wrapper = makeCandidate(fake)
        fake.allowProfileWrite = true; fake.blockProfileWrite = true
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement()
        let write = Task { try await wrapper.setVideoProfile(.low360) }
        await wait { fake.events.contains("profile") }
        let stop = Task { await wrapper.stop() }
        await wait { fake.stops == 1 }
        // Stop of the transport does not prove a separately suspended setter has joined.
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(fake.exports, 0)
        fake.releaseProfileWrite()
        _ = try await write.value
        await stop.value
        XCTAssertEqual(fake.exports, 1)
    }

    func testLifecycleCapturesAuthorityBeforeRevocationAndKeepsClosedMeasurement() async throws {
        let fake = CandidateFixtureFake()
        let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
        let wrapper = makeCandidate(fake, candidateHeadroom: true, poll: .seconds(10), lifecycle: audit,
            profileReceipt: { fake.receivedProfile($0) }, joinedStop: { fake.markJoinedStop() })
        fake.produceTypedCost = true; fake.allowProfileWrite = true; fake.allowBitRateWrite = true; fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }
        fake.finish(); await wrapper.waitForMeasurement()
        let snapshot = await wrapper.candidateSnapshot()
        let candidate = try XCTUnwrap(snapshot)
        let receipt = try await wrapper.setVideoProfile(.low360)
        XCTAssertFalse(candidate.permitsCurrentCandidate(candidate.cost.id))
        _ = try await wrapper.setVideoBitRate(600_000)
        _ = try await wrapper.setVideoProfile(.low240)
        async let first: Void = wrapper.stop()
        async let second: Void = wrapper.stop()
        _ = await (first, second)
        let object = try XCTUnwrap(fake.lifecycleObject)
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["isClosed"] as? Bool, true)
        XCTAssertEqual(object["overflow"] as? Bool, false)
        let rows = try XCTUnwrap(object["profileRequests"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0]["requestID"] as? String, rows[1]["requestID"] as? String)
        XCTAssertEqual(rows[0]["candidateMeasurementID"] as? String, candidate.cost.id.uuidString)
        XCTAssertEqual(rows[1]["candidateMeasurementID"] as? String, candidate.cost.id.uuidString)
        XCTAssertEqual(rows[0]["authorityPermitted"] as? Bool, true)
        XCTAssertEqual(rows[1]["authorityPermitted"] as? Bool, false)
        XCTAssertEqual(rows[0]["targetProfile"] as? String, "360p30")
        XCTAssertEqual(rows[1]["targetProfile"] as? String, "240p30")
        let binding = try XCTUnwrap(rows[0]["probeBinding"] as? [String: Any])
        let observation = try XCTUnwrap(binding["observation"] as? [String: Any])
        XCTAssertEqual(observation["id"] as? String, candidate.binding.id.uuidString)
        let native = try XCTUnwrap(rows[0]["receipt"] as? [String: Any])
        XCTAssertEqual(native["encoderSessionID"] as? String, receipt.encoderSessionID.uuidString)
        XCTAssertEqual(native["acknowledgedAt"] as? Double, receipt.acknowledgedAt)
        let completed = try XCTUnwrap(rows[0]["completedAt"] as? Double)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rows[0]["requestedAt"] as? Double), receipt.acknowledgedAt)
        XCTAssertGreaterThanOrEqual(completed, receipt.acknowledgedAt)
        let terminal = try XCTUnwrap(rows[0]["terminalProbeRead"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(terminal["startedAt"] as? Double), completed)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(terminal["completedAt"] as? Double), try XCTUnwrap(terminal["startedAt"] as? Double))
        XCTAssertNil(terminal["acknowledgedAt"])
        let rates = try XCTUnwrap(object["bitRateRequests"] as? [[String: Any]])
        XCTAssertEqual(rates.count, 1)
        XCTAssertEqual(rates[0]["profileRequestID"] as? String, rows[0]["requestID"] as? String)
        XCTAssertEqual((rates[0]["receipt"] as? [String: Any])?["bitRate"] as? Int, 600_000)
        XCTAssertEqual(fake.receivedProfiles.count, 2)
        XCTAssertEqual(fake.joinedStops, 1)
        XCTAssertEqual(fake.lifecycleExports, 1)
        XCTAssertTrue(fake.object?["invalidReason"] is NSNull, "measured candidate closes before configuration retirement")
        // The closed candidate's final probe is never replaced by lifecycle reads.
        let closedBinding = try XCTUnwrap(fake.object?["probeBinding"] as? [String: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap((closedBinding["final"] as? [String: Any])?["observedAt"] as? Double), candidate.completedAt)
    }

    func testLifecycleFailureMissingProbeAndOverflowRemainBoundedDiagnostics() async throws {
        let fake = CandidateFixtureFake()
        let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
        let wrapper = makeCandidate(fake, lifecycle: audit)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }; fake.finish(); await wrapper.waitForMeasurement()
        for _ in 0..<18 {
            do { _ = try await wrapper.setVideoProfile(.low240); XCTFail("expected native error") } catch {}
        }
        await wrapper.stop()
        let object = try XCTUnwrap(fake.lifecycleObject)
        XCTAssertEqual(object["overflow"] as? Bool, true)
        XCTAssertEqual(object["invalid"] as? Bool, true)
        let rows = try XCTUnwrap(object["profileRequests"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(Set(rows.compactMap { $0["requestID"] as? String }).count, 16)
        XCTAssertTrue(rows.allSatisfy { $0["outcome"] as? String == "failed" && $0["receipt"] is NSNull })
        XCTAssertTrue(rows.allSatisfy { ($0["terminalProbeRead"] as? [String: Any])?["observation"] is NSNull })
        XCTAssertEqual(fake.exports, 1)
    }

    func testLifecycleStopJoinsTerminalObservationAndRejectsNewDispatch() async throws {
        let fake = CandidateFixtureFake()
        let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
        let wrapper = makeCandidate(fake, lifecycle: audit, joinedStop: { fake.markJoinedStop() })
        fake.allowProfileWrite = true
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }; fake.finish(); await wrapper.waitForMeasurement()
        fake.blockNextProbeRead(); fake.holdProbeAcrossStop = true
        let write = Task { try await wrapper.setVideoProfile(.low360) }
        await wait { fake.probeReadIsBlocked }
        let stop = Task { await wrapper.stop() }
        await wait { fake.stops == 1 }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(fake.lifecycleExports, 0); XCTAssertEqual(fake.joinedStops, 0)
        do { _ = try await wrapper.setVideoProfile(.low240); XCTFail("stop must reject new dispatch") } catch {}
        XCTAssertEqual(fake.events.filter { $0 == "profile" }.count, 1)
        fake.releaseProbeRead(); _ = try await write.value; await stop.value
        XCTAssertEqual(fake.lifecycleExports, 1); XCTAssertEqual(fake.joinedStops, 1)
    }

    func testLifecycleJoinsBitRateWriteAndCapturesConcurrentProfileAsAmbiguous() async throws {
        let fake = CandidateFixtureFake()
        let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
        let wrapper = makeCandidate(fake, lifecycle: audit)
        fake.allowProfileWrite = true; fake.allowBitRateWrite = true; fake.blockBitRateWrite = true
        fake.holdBitRateAcrossStop = true; fake.setProbe(stage: 3)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }; fake.finish(); await wrapper.waitForMeasurement()
        _ = try await wrapper.setVideoProfile(.low360)
        let write = Task { try await wrapper.setVideoBitRate(600_000) }
        await wait { fake.events.contains("bitRate") }
        _ = try await wrapper.setVideoProfile(.low240)
        let stop = Task { await wrapper.stop() }
        await wait { fake.stops == 1 }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(fake.lifecycleExports, 0)
        fake.releaseBitRateWrite(); _ = try await write.value; await stop.value
        let object = try XCTUnwrap(fake.lifecycleObject)
        let profiles = try XCTUnwrap(object["profileRequests"] as? [[String: Any]])
        let rates = try XCTUnwrap(object["bitRateRequests"] as? [[String: Any]])
        XCTAssertEqual(rates[0]["profileRequestID"] as? String, profiles[0]["requestID"] as? String,
            "preserve dispatch-time association rather than relabeling it after an await")
        XCTAssertEqual(rates[0]["profileLinkUnambiguous"] as? Bool, false)
        XCTAssertEqual(object["invalid"] as? Bool, true)
        XCTAssertEqual(fake.lifecycleExports, 1)
    }

    func testLifecycleBitRateFailuresAndOverflowDoNotSuppressNativeOperations() async throws {
        let fake = CandidateFixtureFake()
        let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
        let wrapper = makeCandidate(fake, lifecycle: audit)
        await wrapper.setDiagnostics { fake.pressure }
        try await wrapper.start(); await wait { fake.waiting }; fake.finish(); await wrapper.waitForMeasurement()
        for _ in 0..<50 { do { _ = try await wrapper.setVideoBitRate(123); XCTFail("expected native error") } catch {} }
        await wrapper.stop()
        let object = try XCTUnwrap(fake.lifecycleObject)
        let rates = try XCTUnwrap(object["bitRateRequests"] as? [[String: Any]])
        XCTAssertEqual(rates.count, 48)
        XCTAssertEqual(fake.events.filter { $0 == "bitRate" }.count, 50)
        XCTAssertEqual(object["overflow"] as? Bool, true)
        XCTAssertTrue(rates.allSatisfy { $0["outcome"] as? String == "failed" && $0["failure"] is String })
        XCTAssertEqual(fake.exports, 1)
    }

    func testLifecycleBoundsConcurrentNativeWorkBeforeDispatch() async throws {
        for profile in [true, false] {
            let fake = CandidateFixtureFake()
            let audit = NativeCandidateLifecycleAudit(scope: fake.scope, export: { fake.exportLifecycle($0) })
            let wrapper = makeCandidate(fake, lifecycle: audit)
            fake.allowProfileWrite = true; fake.blockProfileWrite = true
            fake.allowBitRateWrite = true; fake.blockBitRateWrite = true
            await wrapper.setDiagnostics { fake.pressure }
            try await wrapper.start(); await wait { fake.waiting }; fake.finish(); await wrapper.waitForMeasurement()
            let limit = profile ? 16 : 48, event = profile ? "profile" : "bitRate"
            let writes = (0..<limit).map { _ in Task {
                if profile { _ = try await wrapper.setVideoProfile(.low360) }
                else { _ = try await wrapper.setVideoBitRate(600_000) }
            } }
            await wait { fake.events.filter { $0 == event }.count == limit }
            let extra = Task {
                do {
                    if profile { _ = try await wrapper.setVideoProfile(.low360) }
                    else { _ = try await wrapper.setVideoBitRate(600_000) }
                    return true
                } catch { return false }
            }
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertEqual(fake.events.filter { $0 == event }.count, limit)
            fake.releaseProfileWrite(); fake.releaseBitRateWrite()
            for write in writes { try await write.value }
            let accepted = await extra.value
            XCTAssertFalse(accepted, "excess pending work must fail without dispatch")
            await wrapper.stop()
            XCTAssertEqual(fake.lifecycleObject?["overflow"] as? Bool, true)
        }
    }

    private func makeCandidate(_ fake: CandidateFixtureFake, delay: Duration = .zero, candidateHeadroom: Bool = false, probeWaitPolls: Int = 250, poll: Duration = .milliseconds(10), lifecycle: NativeCandidateLifecycleAudit? = nil, profileReceipt: (@Sendable (PublishingVideoProfileChange) -> Void)? = nil, joinedStop: (@Sendable () async -> Void)? = nil) -> NativeCandidatePublisher {
        .init(publisher: fake, scope: fake.scope, liveProfile: .low240,
            operations: fake.operations, timing: .init(delay: delay, poll: poll, maximumPolls: 50, maximumProbeWaitPolls: probeWaitPolls), candidateHeadroom: candidateHeadroom, lifecycle: lifecycle, profileReceipt: profileReceipt, joinedStop: joinedStop)
    }
    private func wait(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        XCTFail("bounded fixture wait expired")
    }
}

import CoreMedia
import CoreVideo
private final class CandidateFixtureFake: MediaPublisher, PublishingProbeObserving, @unchecked Sendable {
    let scope = VideoFrameObservationScope(recordingID: "record", matchID: "match", broadcastGeneration: 1,
        publishingAttemptID: UUID(), appliedProfileRevision: 1)
    let videoStartup = PublishingVideoStartup(profile: .low240, width: PublishingVideoProfile.low240.width,
        height: PublishingVideoProfile.low240.height, publishingGeneration: 7, encoderSessionID: UUID(),
        firstSourcePTS: .zero, submittedAt: 1, completedAt: 1, observedAt: 1)
    private let lock = NSLock()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var storedEvents: [String] = [], storedReasons: [PublishingCandidateMeasurement.Reason] = []
    private var storedWaiting = false, storedStops = 0, storedExports = 0, storedData: Data?
    private var fault: Int?, storedFail = false, storedBlockAppend = false
    private var storedProduceTypedCost = false, storedTypedCostFault: Int?, candidateStartedAt: Double?
    private var storedProducedCost: PublishingCandidateCost?
    var produceTypedCost: Bool { get { lock.withLock { storedProduceTypedCost } } set { lock.withLock { storedProduceTypedCost = newValue } } }
    var typedCostFault: Int? { get { lock.withLock { storedTypedCostFault } } set { lock.withLock { storedTypedCostFault = newValue } } }
    var producedCost: PublishingCandidateCost? { lock.withLock { storedProducedCost } }
    private var storedAllowBitRateWrite = false, storedBlockBitRateWrite = false
    private var storedLifecycleData: Data?, storedLifecycleExports = 0, storedJoinedStops = 0
    private var storedReceivedProfiles: [PublishingVideoProfileChange] = [], storedHoldProbeAcrossStop = false
    var lifecycleExports: Int { lock.withLock { storedLifecycleExports } }
    var joinedStops: Int { lock.withLock { storedJoinedStops } }
    var receivedProfiles: [PublishingVideoProfileChange] { lock.withLock { storedReceivedProfiles } }
    var holdProbeAcrossStop: Bool { get { lock.withLock { storedHoldProbeAcrossStop } } set { lock.withLock { storedHoldProbeAcrossStop = newValue } } }
    var lifecycleObject: [String: Any]? { lock.withLock { storedLifecycleData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } } }
    func exportLifecycle(_ data: Data) { lock.withLock { storedLifecycleData = data; storedLifecycleExports += 1 } }
    func receivedProfile(_ receipt: PublishingVideoProfileChange) { lock.withLock { storedReceivedProfiles.append(receipt) } }
    func markJoinedStop() { lock.withLock { storedJoinedStops += 1 } }
    private var storedHoldBitRateAcrossStop = false
    var holdBitRateAcrossStop: Bool { get { lock.withLock { storedHoldBitRateAcrossStop } } set { lock.withLock { storedHoldBitRateAcrossStop = newValue } } }
    private var storedAllowProfileWrite = false, storedBlockProfileWrite = false
    private let profileGate = AsyncStream<Void>.makeStream()
    var allowProfileWrite: Bool { get { lock.withLock { storedAllowProfileWrite } } set { lock.withLock { storedAllowProfileWrite = newValue } } }
    var blockProfileWrite: Bool { get { lock.withLock { storedBlockProfileWrite } } set { lock.withLock { storedBlockProfileWrite = newValue } } }
    func releaseProfileWrite() { profileGate.continuation.finish() }
    func setVideoProfile(_ value: PublishingVideoProfile) async throws -> PublishingVideoProfileChange {
        lock.withLock { storedEvents.append("profile") }
        if blockProfileWrite { for await _ in profileGate.stream {} }
        guard allowProfileWrite, let startup = videoStartup,
              let receipt = PublishingVideoProfileChange(profile: value, publishingGeneration: startup.publishingGeneration,
                previousEncoderSessionID: startup.encoderSessionID, encoderSessionID: UUID(),
                lastOldSourcePTS: .zero, firstNewSourcePTS: CMTime(value: 1, timescale: 30),
                width: value.width, height: value.height, rawVideoFramesDropped: 0,
                acknowledgedAt: ProcessInfo.processInfo.systemUptime)
        else { throw PublishingSessionError.invalidState }
        return receipt
    }
    private let bitRateGate = AsyncStream<Void>.makeStream()
    var allowBitRateWrite: Bool { get { lock.withLock { storedAllowBitRateWrite } } set { lock.withLock { storedAllowBitRateWrite = newValue } } }
    var blockBitRateWrite: Bool { get { lock.withLock { storedBlockBitRateWrite } } set { lock.withLock { storedBlockBitRateWrite = newValue } } }
    func releaseBitRateWrite() { bitRateGate.continuation.finish() }
    private let appendGate = AsyncStream<Void>.makeStream()
    private let startGate = AsyncStream<Void>.makeStream()
    private var storedBlockStart = false, storedBlockCandidateStart = false
    private let candidateStartGate = AsyncStream<Void>.makeStream()
    var blockCandidateStart: Bool { get { lock.withLock { storedBlockCandidateStart } } set { lock.withLock { storedBlockCandidateStart = newValue } } }
    func releaseCandidateStart() { candidateStartGate.continuation.finish() }
    func updateProbeLease(after interval: Double) { lock.withLock { probe?.leaseDeadline = ProcessInfo.processInfo.systemUptime + interval } }
    private var probe: PublishingProbeObservation?, storedProbeReads = 0, authority = true
    private var lastReturnedProbeBytes: UInt64?, storedPressureProbeBytes: UInt64?
    var pressureProbeBytes: UInt64? { lock.withLock { storedPressureProbeBytes } }
    func advanceProbeReceipt() {
        lock.withLock {
            probe?.acceptedPayloadBytes = 2 * 1316
            probe?.lastAcceptedAt = ProcessInfo.processInfo.systemUptime
            probe?.leaseDeadline = ProcessInfo.processInfo.systemUptime + 20
        }
    }
    func regressProbeReceipt() {
        lock.withLock {
            probe?.acceptedPayloadBytes = 1316
            probe?.leaseDeadline = ProcessInfo.processInfo.systemUptime + 10
        }
    }
    private let probeReadGate = AsyncStream<Void>.makeStream()
    private var storedBlockNextProbeRead = false, storedProbeReadIsBlocked = false
    func blockNextProbeRead() { lock.withLock { storedBlockNextProbeRead = true } }
    func releaseProbeRead() { probeReadGate.continuation.finish() }
    var probeReadIsBlocked: Bool { lock.withLock { storedProbeReadIsBlocked } }
    var probeReads: Int { lock.withLock { storedProbeReads } }
    func setProbe(stage: Int, age: Double = 1) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            authority = true
            probe = .init(id: UUID(), publishingGeneration: 7, bitRate: stage == 3 ? 12_000_000 : 2_000_000,
                startedAt: now - age, leaseDeadline: now + 10, acceptedPayloadBytes: 1316,
                lastAcceptedAt: now, reason: nil, stage: stage,
                permitsCurrentOwner: { [weak self] _,_,_ in self?.lock.withLock { self?.authority == true } ?? false })
        }
    }
    func mutateProbe(_ fault: Int) {
        lock.withLock {
            switch fault {
            case 0: probe = nil
            case 1: probe?.reason = "cancelled"
            case 2: probe?.stage = 2
            case 3: probe?.leaseDeadline = ProcessInfo.processInfo.systemUptime - 0.1
            case 4: authority = false
            case 5: probe?.bitRate = 2_000_000
            case 6: probe?.id = UUID()
            default: probe?.publishingGeneration = 8
            }
        }
    }
    func probeObservation() async -> PublishingProbeObservation? {
        let (value, block) = lock.withLock {
            storedProbeReads += 1
            let block = storedBlockNextProbeRead
            storedBlockNextProbeRead = false
            if block { storedProbeReadIsBlocked = true }
            return (probe, block)
        }
        if block { for await _ in probeReadGate.stream {} }
        lock.withLock { lastReturnedProbeBytes = value?.acceptedPayloadBytes }
        return value
    }
    init() { let pair = AsyncStream<Void>.makeStream(); stream = pair.stream; continuation = pair.continuation }
    var events: [String] { lock.withLock { storedEvents } }
    var reasons: [PublishingCandidateMeasurement.Reason] { lock.withLock { storedReasons } }
    var waiting: Bool { lock.withLock { storedWaiting } }
    var stops: Int { lock.withLock { storedStops } }
    var exports: Int { lock.withLock { storedExports } }
    var object: [String: Any]? { lock.withLock { storedData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } } }
    var failAppend: Bool { get { lock.withLock { storedFail } } set { lock.withLock { storedFail = newValue } } }
    var blockStart: Bool { get { lock.withLock { storedBlockStart } } set { lock.withLock { storedBlockStart = newValue } } }
    func releaseStart() { startGate.continuation.finish() }
    var blockAppend: Bool { get { lock.withLock { storedBlockAppend } } set { lock.withLock { storedBlockAppend = newValue } } }
    func releaseAppend() { appendGate.continuation.finish() }
    func setFault(_ value: Int) { lock.withLock { fault = value } }
    var pressure: NativeCandidatePublisher.Pressure? {
        lock.withLock {
            storedPressureProbeBytes = lastReturnedProbeBytes
            if fault == 4 { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            return .init(observedAt: now, sampledAt: now - (fault == 2 ? 3 : 0), thermal: fault == 1 ? 2 : 0,
                dropped: fault == 0 ? 1 : 0, rejected: fault == 3 ? 1 : 0, publishing: true)
        }
    }
    var operations: NativeCandidatePublisher.Operations {
        .init(start: {
            self.lock.withLock { self.storedEvents.append("candidateStart"); self.candidateStartedAt = ProcessInfo.processInfo.systemUptime }
            if self.blockCandidateStart { for await _ in self.candidateStartGate.stream {} }
        },
            offer: { _ in self.lock.withLock { self.storedEvents.append("candidate") }; return true },
            cancel: { reason in self.lock.withLock { self.storedReasons.append(reason) } },
            result: { self.lock.withLock { self.storedWaiting = true }; for await _ in self.stream {}; return Data("{}".utf8) },
            export: { data in self.lock.withLock { self.storedExports += 1; self.storedData = data } },
            typedResult: {
                self.lock.withLock {
                    guard self.storedProduceTypedCost, let start = self.candidateStartedAt else { return nil }
                    let fault = self.storedTypedCostFault
                    let offset = fault == 2 ? -3.0 : fault == 3 ? 3.0 : 0
                    let scope = fault == 0 ? VideoFrameObservationScope(recordingID: "other", matchID: "match", broadcastGeneration: 1,
                        publishingAttemptID: self.scope.publishingAttemptID, appliedProfileRevision: 1) : self.scope
                    let cost = candidateCost(scope: scope, start: start + offset,
                        end: ProcessInfo.processInfo.systemUptime + offset, generation: fault == 1 ? 8 : 7)
                    self.storedProducedCost = cost
                    return cost
                }
            })
    }
    func finish() { continuation.finish() }
    func start() async throws {
        lock.withLock { storedEvents.append("primaryStart") }
        if blockStart { for await _ in startGate.stream {} }
    }
    func append(_ sample: CapturedMediaSample) async throws {
        lock.withLock { storedEvents.append("primary") }
        if blockAppend { for await _ in appendGate.stream {} }
        if failAppend { throw PublishingSessionError.appendFailed }
    }
    var isPublishing: Bool { get async { true } }
    func setVideoBitRate(_ value: Int) async throws -> PublishingBitRateChange {
        lock.withLock { storedEvents.append("bitRate") }
        if blockBitRateWrite { for await _ in bitRateGate.stream {} }
        guard allowBitRateWrite, let startup = videoStartup,
              let configuration = VideoEncodingConfiguration(id: UUID(), encoderSessionID: startup.encoderSessionID, bitRate: value),
              let receipt = PublishingBitRateChange(publishingGeneration: startup.publishingGeneration, configuration: configuration,
                acceptedAt: ProcessInfo.processInfo.systemUptime, lastSubmittedSourcePTS: nil)
        else { throw PublishingSessionError.bitRateUpdateFailed }
        return receipt
    }
    func stop() async { lock.withLock { storedStops += 1 }; releaseAppend(); releaseCandidateStart(); if !holdProbeAcrossStop { releaseProbeRead() }; if !holdBitRateAcrossStop { releaseBitRateWrite() }; finish() }
}
/// Complete typed native evidence with accelerated wall-clock submission. The
/// source still covers four seconds, and the validator uses the shorter duration.
private func candidateCost(scope: VideoFrameObservationScope, start: Double, end: Double,
                           generation: UInt64 = 7) -> PublishingCandidateCost? {
    let id = UUID(), session = UUID()
    let frames: [VideoCandidateEncoder.Frame] = (0...120).map { index in
        let pts = CMTime(value: Int64(index), timescale: 30)
        let at = start + Double(index) / 1_000_000
        return .init(sourcePTS: pts, outputPTS: pts, encoderSessionID: session,
            admittedAt: at, rawByteCount: 16384, submittedAt: at, completedAt: at, dequeuedAt: at,
            byteCount: 1000, width: 640, height: 360, isSync: index == 0)
    }
    let audio: [PublishingCandidateTransport.AudioReceipt] = (0..<188).map { index in
        .init(sourcePTS: CMTime(value: Int64(index * 1024), timescale: 48000), publishingGeneration: generation,
            wasEncoded: true, valid: true, observedAt: start, consumedAt: start, byteCount: 100,
            sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2)
    }
    let following = PublishingCandidateTransport.AudioReceipt(sourcePTS: CMTime(value: 188 * 1024, timescale: 48000),
        publishingGeneration: generation, wasEncoded: true, valid: true, observedAt: start, consumedAt: end,
        byteCount: 100, sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2)
    let inputs: [CandidateTransportMeasurement.Input] = frames.map {
        .init(media: .video, sourcePTS: $0.sourcePTS, decodePTS: $0.sourcePTS,
            byteCount: $0.byteCount, isSync: $0.isSync, parameterSetBytes: $0.isSync ? 24 : 0)
    } + audio.map { .init(media: .audio, sourcePTS: $0.sourcePTS, decodePTS: .invalid,
        byteCount: $0.byteCount, isSync: true, parameterSetBytes: 0) }
    let mux = CandidateTransportMeasurement.Result(inputs: inputs, outcome: .completed, failure: nil,
        videoInputCount: 121, audioInputCount: 188, videoInputBytes: 121000, audioInputBytes: 18800,
        firstVideoPTS: .zero, lastVideoPTS: CMTime(value: 4, timescale: 1),
        firstAudioPTS: audio.first!.sourcePTS, lastAudioPTS: audio.last!.sourcePTS,
        transportBytes: 376000, transportMessageCount: 400)
    let transport = PublishingCandidateTransport.Result(scope: scope, profile: .low360, id: id,
        outcome: .completed, failure: nil, publishingGeneration: generation, startedAt: start,
        closedAt: end, endedAt: end, rawInputCount: 121, firstRawPTS: .zero,
        lastRawPTS: CMTime(value: 4, timescale: 1), audio: audio, followingAudio: following,
        maximumPendingCount: 2, maximumPendingBytes: 200, mux: mux)
    let native = VideoCandidateEncoder.Result(id: id, settings: PublishingVideoProfile.low360.settings,
        outcome: .completed, failure: nil, nativeFailure: nil, encoderSessionID: session,
        acceptedInputCount: 121, outputCount: 121, frames: frames)
    let encoding = PublishingCandidateEncoder.Result(scope: scope, profile: .low360, encoding: native, transport: transport)
    return PublishingCandidateCost(.init(id: id, scope: scope, profile: .low360, reason: .completed,
        startedAt: start, endedAt: end, acceptedInputCount: 121,
        firstInputPTS: .zero, lastInputPTS: CMTime(value: 4, timescale: 1), encoding: encoding))
}

private func candidateVideo(at pts: CMTime = .zero) throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?, format: CMVideoFormatDescription?, sample: CMSampleBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}
