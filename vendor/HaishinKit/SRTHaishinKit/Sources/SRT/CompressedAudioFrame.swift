import AVFoundation
import CoreMedia
import Foundation
import HaishinKit

extension SRTStream {
    /// A bounded, independently owned copy of an accepted live AAC packet.
    /// This is encoder/mux input evidence, not transport-delivery evidence.
    public struct CompressedAudioFrame: Sendable {
        public let sourcePTS: CMTime
        /// Original host-clock tick, preserving exact mux timestamp reconstruction.
        public let hostTime: UInt64
        public let publishingGeneration: UInt64
        public let wasEncoded: Bool
        public let observedAt: Double
        public let valid: Bool
        public let sampleRate: Double
        public let channelCount: UInt32
        public let framesPerPacket: UInt32
        public let audioObjectType: UInt32
        public let payload: Data
        public var byteCount: Int { payload.count }

        init(buffer: AVAudioCompressedBuffer, when: AVAudioTime, generation: UInt64,
             wasEncoded: Bool, observedAt: Double = ProcessInfo.processInfo.systemUptime) {
            let asbd = buffer.format.streamDescription.pointee
            let pts = when.isHostTimeValid ? when.makeTime() : CMTime.invalid
            sourcePTS = pts; hostTime = when.hostTime; publishingGeneration = generation
            self.wasEncoded = wasEncoded; self.observedAt = observedAt
            sampleRate = asbd.mSampleRate; channelCount = asbd.mChannelsPerFrame
            framesPerPacket = asbd.mFramesPerPacket; audioObjectType = asbd.mFormatFlags
            // Validate actual length and packet metadata before allocating or
            // copying any payload from a potentially pooled codec buffer.
            guard generation > 0, observedAt.isFinite, observedAt >= 0,
                  pts.isNumeric, pts.timescale > 0, pts.epoch == 0, pts.value >= 0,
                  buffer.byteLength > 0, buffer.byteLength <= 8184, buffer.byteLength <= buffer.byteCapacity,
                  buffer.packetCount == 1, asbd.mFormatID == kAudioFormatMPEG4AAC,
                  asbd.mFormatFlags == 2, asbd.mFramesPerPacket == 1024,
                  [96_000.0, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350].contains(asbd.mSampleRate),
                  (1...6).contains(asbd.mChannelsPerFrame) || asbd.mChannelsPerFrame == 8,
                  let packet = buffer.packetDescriptions?.pointee, packet.mStartOffset == 0,
                  packet.mDataByteSize == buffer.byteLength,
                  packet.mVariableFramesInPacket == 0 || packet.mVariableFramesInPacket == 1024 else {
                valid = false; payload = Data(); return
            }
            valid = true
            payload = Data(bytes: buffer.data, count: Int(buffer.byteLength))
        }
    }
}
