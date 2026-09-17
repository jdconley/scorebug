import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import HaishinKit
@testable import SRTHaishinKit
@testable import ScorebugStreaming

final class PublishingCandidateCostTests: XCTestCase {
    enum Fault: CaseIterable {
        case cancelled, missingEncoding, encoderFailure, wrongIdentity, wrongScope, wrongProfile, wrongRecipe
        case incompleteFrames, noSync, wrongDimensions, wrongSession, slowSubmission, lateOutput, futureOutput
        case wrongMux, missingAudio, missingFollowing, missingMux, transportFailure, wrongGeneration
        case invalidTime, nonmonotonicPTS, missingRawPTS, excessiveTransportBytes, excessiveMessages
        case audioGeneration, audioNotEncoded, audioInvalid, audioRate, audioRateChanged, audioChannels, audioChannelsChanged
        case audioPacketFrames, audioObjectType, audioEmpty, audioOversized, audioReordered, audioGap
        case audioBeforeWindow, audioObservedInFuture, audioConsumedBeforeObservation, audioConsumedAfterEnd, audioClockRewind, audioInvalidClock
        case followingGeneration, followingNotAfterWindow, followingGap, followingBeforeClose, followingAfterDeadline
        case videoDecodeTime, videoIndefiniteDecodeTime, missingParameters, excessiveParameters, changedParameters, nonsyncParameters
        case audioDecodeTime, audioParameters, audioNotSync, combinedInputBytes
    }
    private func fixture(_ fault: Fault? = nil, videoPayloadBytes: Int? = nil,
                         videoDecodePTS: CMTime? = nil, parameterSetBytes: Int = 24) -> PublishingCandidateMeasurement.Result {
        let id = UUID(), encoderID = UUID()
        let scope = VideoFrameObservationScope(recordingID: "recording", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: UUID(), appliedProfileRevision: 1)
        let otherScope = VideoFrameObservationScope(recordingID: "other", matchID: "match", broadcastGeneration: 1,
            publishingAttemptID: scope.publishingAttemptID, appliedProfileRevision: 1)
        let count = fault == .incompleteFrames ? 120 : 121
        let totalVideoBytes = fault == .combinedInputBytes ? 32 * 1024 * 1024 - 18800 + 1 : videoPayloadBytes ?? count * 1000
        let frames: [VideoCandidateEncoder.Frame] = (0..<count).map { n in
            let pts = CMTime(value: Int64(fault == .nonmonotonicPTS && n == 60 ? 59 : n), timescale: 30)
            let at = 10 + Double(n) / 30
            return .init(sourcePTS: pts, outputPTS: pts, encoderSessionID: fault == .wrongSession && n == 60 ? UUID() : encoderID,
                admittedAt: at, rawByteCount: 16384,
                submittedAt: at + 0.01 + (fault == .slowSubmission ? Double(n) / 30 : 0),
                completedAt: at + (fault == .lateOutput ? 1.6 : 0.02),
                dequeuedAt: fault == .futureOutput && n == 120 ? 15 : at + (fault == .lateOutput ? 1.61 : 0.03),
                byteCount: totalVideoBytes / count + (n < totalVideoBytes % count ? 1 : 0),
                width: fault == .wrongDimensions ? 960 : 640, height: 360,
                isSync: fault != .noSync && (n == 0 || n == 60))
        }
        let audio: [PublishingCandidateTransport.AudioReceipt] = (0..<188).map { n in
            let changed = n == 60
            let packetIndex = changed && fault == .audioReordered ? 59 : changed && fault == .audioGap ? 61 : n
            let pts = CMTime(value: Int64(packetIndex * 1024), timescale: 48000)
            var observedAt = 10 + pts.seconds
            var consumedAt = (fault == .followingBeforeClose ? 10.005 : 10.025) + pts.seconds
            if n == 0 && fault == .audioBeforeWindow { observedAt = 9.99 }
            if changed && fault == .audioObservedInFuture { observedAt = 15 }
            if changed && fault == .audioConsumedBeforeObservation { consumedAt = observedAt - 0.001 }
            if changed && fault == .audioConsumedAfterEnd { consumedAt = 15 }
            if changed && fault == .audioClockRewind { observedAt -= 0.1; consumedAt -= 0.1 }
            if changed && fault == .audioInvalidClock { observedAt = .nan }
            return .init(sourcePTS: pts, publishingGeneration: changed && fault == .audioGeneration ? 8 : 7,
                wasEncoded: !(changed && fault == .audioNotEncoded), valid: !(changed && fault == .audioInvalid),
                observedAt: observedAt, consumedAt: consumedAt,
                byteCount: changed && fault == .audioEmpty ? 0 : changed && fault == .audioOversized ? 8185 : 100,
                sampleRate: changed && fault == .audioRate ? 12345 : changed && fault == .audioRateChanged ? 44100 : 48000,
                channelCount: changed && fault == .audioChannels ? 7 : changed && fault == .audioChannelsChanged ? 1 : 2,
                framesPerPacket: changed && fault == .audioPacketFrames ? 2048 : 1024,
                audioObjectType: changed && fault == .audioObjectType ? 1 : 2)
        }
        let followingPTS = fault == .followingNotAfterWindow ? CMTime(value: 4, timescale: 1)
            : CMTime(value: (fault == .followingGap ? 189 : 188) * 1024, timescale: 48000)
        let following = PublishingCandidateTransport.AudioReceipt(sourcePTS: followingPTS,
            publishingGeneration: fault == .followingGeneration ? 8 : 7,
            wasEncoded: true, valid: true,
            observedAt: fault == .followingBeforeClose ? 13.995 : 14.011,
            consumedAt: fault == .followingBeforeClose ? 13.996 : fault == .followingAfterDeadline ? 15.001 : 14.03,
            byteCount: 100, sampleRate: 48000, channelCount: 2, framesPerPacket: 1024, audioObjectType: 2)
        let videoInputs: [CandidateTransportMeasurement.Input] = frames.enumerated().map { n, frame in
            var decode = videoDecodePTS ?? frame.sourcePTS
            if n == 1 && fault == .videoDecodeTime { decode = CMTime(value: -1, timescale: 30) }
            if n == 1 && fault == .videoIndefiniteDecodeTime { decode = .indefinite }
            var parameters = frame.isSync ? parameterSetBytes : 0
            if n == 0 && fault == .missingParameters { parameters = 9 }
            if n == 0 && fault == .excessiveParameters { parameters = 65601 }
            if n == 60 && fault == .changedParameters { parameters += 1 }
            if n == 1 && fault == .nonsyncParameters { parameters = 24 }
            return .init(media: .video, sourcePTS: frame.sourcePTS, decodePTS: decode,
                byteCount: frame.byteCount, isSync: frame.isSync, parameterSetBytes: parameters)
        }
        let inputs = videoInputs + audio.enumerated().map { n, packet in
            CandidateTransportMeasurement.Input(media: .audio, sourcePTS: packet.sourcePTS,
                decodePTS: n == 60 && fault == .audioDecodeTime ? .zero : .invalid,
                byteCount: packet.byteCount, isSync: !(n == 60 && fault == .audioNotSync),
                parameterSetBytes: n == 60 && fault == .audioParameters ? 1 : 0)
        }
        let largePayload = videoPayloadBytes != nil || fault == .combinedInputBytes
        let transportBytes = largePayload ? ((totalVideoBytes + 18800 + 64000 + 187) / 188) * 188 : 376000
        let transportMessages = largePayload ? (transportBytes + 1315) / 1316 : 400
        let mux = CandidateTransportMeasurement.Result(inputs: inputs, outcome: .completed, failure: nil,
            videoInputCount: fault == .wrongMux ? 1 : count, audioInputCount: 188,
            videoInputBytes: totalVideoBytes, audioInputBytes: audio.reduce(0) { $0 + $1.byteCount },
            firstVideoPTS: .zero, lastVideoPTS: CMTime(value: 4, timescale: 1),
            firstAudioPTS: audio.first!.sourcePTS, lastAudioPTS: audio.last!.sourcePTS,
            transportBytes: fault == .excessiveTransportBytes ? 41 * 1024 * 1024 : transportBytes,
            transportMessageCount: fault == .excessiveMessages ? 250001 : transportMessages)
        let transport = PublishingCandidateTransport.Result(scope: scope, profile: .low360, id: id,
            outcome: fault == .transportFailure ? .failed : .completed, failure: fault == .transportFailure ? "failed" : nil,
            publishingGeneration: fault == .wrongGeneration ? 0 : 7, startedAt: 10, closedAt: 14,
            endedAt: fault == .followingAfterDeadline ? 15.04 : 14.04,
            rawInputCount: count, firstRawPTS: .zero, lastRawPTS: CMTime(value: 4, timescale: 1),
            audio: fault == .missingAudio ? [] : audio, followingAudio: fault == .missingFollowing ? nil : following,
            maximumPendingCount: 2, maximumPendingBytes: 200, mux: fault == .missingMux ? nil : mux)
        var settings = PublishingVideoProfile.low360.settings
        if fault == .wrongRecipe { settings.bitRate += 1 }
        let encoded = VideoCandidateEncoder.Result(id: fault == .wrongIdentity ? UUID() : id, settings: settings,
            outcome: fault == .encoderFailure ? .failed : .completed, failure: nil, nativeFailure: nil,
            encoderSessionID: encoderID, acceptedInputCount: count, outputCount: count, frames: frames)
        let encoding = PublishingCandidateEncoder.Result(scope: fault == .wrongScope ? otherScope : scope,
            profile: fault == .wrongProfile ? .sd540 : .low360, encoding: encoded, transport: transport)
        return .init(id: id, scope: scope, profile: .low360, reason: fault == .cancelled ? .cancelled : .completed,
            startedAt: fault == .invalidTime ? .nan : 10,
            endedAt: fault == .followingAfterDeadline ? 15.06 : 14.06, acceptedInputCount: 121,
            firstInputPTS: fault == .missingRawPTS ? nil : .zero, lastInputPTS: CMTime(value: 4, timescale: 1),
            encoding: fault == .missingEncoding ? nil : encoding)
    }
    func testJoinedResultProducesActualPayloadCostWithoutClaimingCapacity() throws {
        let result = fixture(), cost = try XCTUnwrap(PublishingCandidateCost(result))
        XCTAssertEqual(cost.id, result.id); XCTAssertEqual(cost.scope, result.scope)
        XCTAssertEqual(cost.profile, .low360); XCTAssertEqual(cost.publishingGeneration, 7)
        XCTAssertEqual(cost.transportBytes, 376000); XCTAssertEqual(cost.transportMessageCount, 400)
        XCTAssertEqual(cost.sourceDuration, 4); XCTAssertEqual(cost.submissionDuration, 4, accuracy: 1e-9)
        XCTAssertEqual(cost.applicationPayloadBitsPerSecond, 752000, accuracy: 1e-6)
        XCTAssertEqual(cost.firstInputAt, 10); XCTAssertEqual(cost.lastInputAt, 14)
        XCTAssertEqual(cost.startedAt, 10); XCTAssertEqual(cost.endedAt, 14.06)
    }
    func testIncompleteMismatchedOrUnusableMeasurementsCannotBecomeCostEvidence() {
        for fault in Fault.allCases { XCTAssertNil(PublishingCandidateCost(fixture(fault)), "\(fault)") }
    }
    func testNativeMuxMetadataAllowsInvalidOrNumericVideoDecodeTimes() {
        for decode in [CMTime.invalid, .zero, CMTime(value: 1, timescale: 60)] {
            XCTAssertNotNil(PublishingCandidateCost(fixture(videoDecodePTS: decode)))
        }
        for parameters in [10, 65600] {
            XCTAssertNotNil(PublishingCandidateCost(fixture(parameterSetBytes: parameters)))
        }
    }
    func testCombinedCompressedInputLimitIncludesAudioAndAcceptsExactBoundary() {
        XCTAssertNotNil(PublishingCandidateCost(fixture(videoPayloadBytes: 32 * 1024 * 1024 - 18800)))
        XCTAssertNil(PublishingCandidateCost(fixture(.combinedInputBytes)))
    }
}
