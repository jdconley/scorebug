import CoreMedia
import Foundation
import ScorebugMedia

/// Joined native whole-stream payload cost; it is not receiver capacity.
public struct PublishingCandidateCost: Sendable {
    public let id: UUID
    public let scope: VideoFrameObservationScope
    public let profile: PublishingVideoProfile
    public let publishingGeneration: UInt64
    public let startedAt: Double
    public let endedAt: Double
    public let firstInputAt: Double
    public let lastInputAt: Double
    public let sourceDuration: Double
    public let submissionDuration: Double
    public let transportBytes: Int
    public let transportMessageCount: Int
    public var applicationPayloadBitsPerSecond: Double {
        Double(transportBytes) * 8 / min(sourceDuration, submissionDuration)
    }
    public init?(_ result: PublishingCandidateMeasurement.Result) {
        func clock(_ value: Double) -> Bool { value.isFinite && (0...1e12).contains(value) }
        func pts(_ value: CMTime) -> Bool {
            value.isNumeric && value.timescale > 0 && value.epoch == 0 && value.value >= 0
        }
        func equal(_ lhs: CMTime?, _ rhs: CMTime) -> Bool {
            lhs.map { pts($0) && CMTimeCompare($0, rhs) == 0 } ?? false
        }
        guard result.reason == .completed, let start = result.startedAt,
              clock(start), clock(result.endedAt), result.endedAt >= start, result.endedAt - start <= 7,
              let encoding = result.encoding, encoding.scope == result.scope, encoding.profile == result.profile,
              let firstPTS = result.firstInputPTS, let lastPTS = result.lastInputPTS,
              pts(firstPTS), pts(lastPTS) else { return nil }
        let native = encoding.encoding
        let count = result.acceptedInputCount
        let sourceDuration = CMTimeSubtract(lastPTS, firstPTS).seconds
        let recipeEncoder = JSONEncoder()
        recipeEncoder.outputFormatting = .sortedKeys
        guard native.id == result.id, native.outcome == .completed,
              native.failure == nil, native.nativeFailure == nil, let sessionID = native.encoderSessionID,
              let requested = try? recipeEncoder.encode(native.settings),
              let expected = try? recipeEncoder.encode(result.profile.settings), requested == expected,
              (97...121).contains(count), native.acceptedInputCount == count,
              native.outputCount == count, native.frames.count == count,
              let first = native.frames.first, let last = native.frames.last, first.isSync,
              equal(first.sourcePTS, firstPTS), equal(last.sourcePTS, lastPTS),
              sourceDuration.isFinite, (4...4.25).contains(sourceDuration),
              Double(count - 1) / sourceDuration >= 24 else { return nil }
        let submissionDuration = last.submittedAt - first.submittedAt
        guard submissionDuration.isFinite, submissionDuration > 0,
              Double(count - 1) / submissionDuration >= 24 else { return nil }
        var videoBytes = 0
        for (index, frame) in native.frames.enumerated() {
            guard pts(frame.sourcePTS), equal(frame.outputPTS, frame.sourcePTS), frame.encoderSessionID == sessionID,
                  frame.width == result.profile.width,
                  frame.height == result.profile.height,
                  (1...2 * 1024 * 1024).contains(frame.byteCount),
                  (1...16 * 1024 * 1024).contains(frame.rawByteCount),
                  [frame.admittedAt, frame.submittedAt, frame.completedAt, frame.dequeuedAt].allSatisfy(clock),
                  start <= frame.admittedAt, frame.admittedAt <= frame.submittedAt,
                  frame.submittedAt <= frame.completedAt, frame.completedAt <= frame.dequeuedAt,
                  frame.dequeuedAt <= result.endedAt, frame.submittedAt - start < 5,
                  frame.dequeuedAt - frame.submittedAt <= 1.5,
                  frame.byteCount <= 32 * 1024 * 1024 - videoBytes else { return nil }
            if index > 0 {
                let previous = native.frames[index - 1]
                guard CMTimeCompare(previous.sourcePTS, frame.sourcePTS) < 0,
                      previous.admittedAt < frame.admittedAt, previous.submittedAt < frame.submittedAt,
                      previous.dequeuedAt <= frame.dequeuedAt else { return nil }
            }
            videoBytes += frame.byteCount
        }
        guard let transport = encoding.transport, transport.id == result.id,
              transport.scope == result.scope, transport.profile == result.profile,
              transport.outcome == .completed, transport.failure == nil,
              let generation = transport.publishingGeneration, generation > 0,
              let transportStart = transport.startedAt, let closed = transport.closedAt,
              [transportStart, closed, transport.endedAt].allSatisfy(clock),
              start <= transportStart, transportStart <= first.admittedAt,
              last.admittedAt <= closed, closed <= transport.endedAt, transport.endedAt <= result.endedAt,
              transport.rawInputCount == count, equal(transport.firstRawPTS, firstPTS), equal(transport.lastRawPTS, lastPTS),
              (0...16).contains(transport.maximumPendingCount), (0...128 * 1024).contains(transport.maximumPendingBytes),
              (1...512).contains(transport.audio.count), let following = transport.followingAudio,
              let firstAudio = transport.audio.first, let lastAudio = transport.audio.last,
              let mux = transport.mux, mux.outcome == .completed, mux.failure == nil else { return nil }
        var audioBytes = 0
        let audio = transport.audio + [following]
        for (index, packet) in audio.enumerated() {
            guard pts(packet.sourcePTS), packet.valid, packet.wasEncoded, packet.publishingGeneration == generation,
                  packet.framesPerPacket == 1024, packet.audioObjectType == 2,
                  [96_000.0, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350].contains(packet.sampleRate),
                  (1...6).contains(packet.channelCount) || packet.channelCount == 8,
                  (1...8184).contains(packet.byteCount), clock(packet.observedAt), clock(packet.consumedAt),
                  start <= packet.observedAt, transportStart <= packet.consumedAt,
                  packet.observedAt <= packet.consumedAt,
                  packet.consumedAt <= transport.endedAt,
                  packet.sampleRate == firstAudio.sampleRate, packet.channelCount == firstAudio.channelCount else { return nil }
            if index > 0 {
                let previous = audio[index - 1]
                let delta = CMTimeSubtract(packet.sourcePTS, previous.sourcePTS).seconds
                guard delta > 0, abs(delta - 1024 / packet.sampleRate) <= 0.000000100,
                      previous.observedAt <= packet.observedAt, previous.consumedAt <= packet.consumedAt else { return nil }
            }
            if index < transport.audio.count {
                guard CMTimeCompare(packet.sourcePTS, firstPTS) >= 0, CMTimeCompare(packet.sourcePTS, lastPTS) <= 0 else { return nil }
                audioBytes += packet.byteCount
            }
        }
        guard CMTimeSubtract(firstAudio.sourcePTS, firstPTS).seconds <= 1024 / firstAudio.sampleRate + 0.000000100,
              CMTimeCompare(following.sourcePTS, lastPTS) > 0,
              CMTimeSubtract(following.sourcePTS, lastPTS).seconds <= 1024 / following.sampleRate + 0.000000100,
              following.consumedAt >= closed, following.consumedAt - closed <= 1,
              videoBytes <= 32 * 1024 * 1024 - audioBytes,
              mux.videoInputCount == count, mux.audioInputCount == transport.audio.count,
              mux.videoInputBytes == videoBytes, mux.audioInputBytes == audioBytes,
              equal(mux.firstVideoPTS, firstPTS), equal(mux.lastVideoPTS, lastPTS),
              equal(mux.firstAudioPTS, firstAudio.sourcePTS), equal(mux.lastAudioPTS, lastAudio.sourcePTS),
              (1...40 * 1024 * 1024).contains(mux.transportBytes), mux.transportBytes % 188 == 0,
              (1...250_000).contains(mux.transportMessageCount),
              mux.transportMessageCount * 188 <= mux.transportBytes,
              mux.transportBytes <= mux.transportMessageCount * 1316,
              mux.transportBytes >= videoBytes + audioBytes,
              mux.inputs.count == count + transport.audio.count else { return nil }
        let videos = mux.inputs.filter { $0.media == .video }
        let audios = mux.inputs.filter { $0.media == .audio }
        guard videos.count == count, audios.count == transport.audio.count,
              let parameterBytes = videos.first?.parameterSetBytes, (10...65600).contains(parameterBytes),
              zip(videos, native.frames).allSatisfy({ input, frame in
                  equal(input.sourcePTS, frame.sourcePTS) && input.byteCount == frame.byteCount && input.isSync == frame.isSync
                      && (input.decodePTS == .invalid || pts(input.decodePTS))
                      && input.parameterSetBytes == (input.isSync ? parameterBytes : 0)
              }), zip(audios, transport.audio).allSatisfy({ input, packet in
                  equal(input.sourcePTS, packet.sourcePTS) && input.byteCount == packet.byteCount && input.isSync
                      && input.decodePTS == .invalid && input.parameterSetBytes == 0
              }) else { return nil }
        id = result.id; scope = result.scope; profile = result.profile; publishingGeneration = generation
        startedAt = start; endedAt = result.endedAt; firstInputAt = first.admittedAt; lastInputAt = last.admittedAt
        self.sourceDuration = sourceDuration; self.submissionDuration = submissionDuration
        transportBytes = mux.transportBytes; transportMessageCount = mux.transportMessageCount
    }
}
