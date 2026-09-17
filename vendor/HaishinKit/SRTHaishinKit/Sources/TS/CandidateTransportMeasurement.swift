import AVFoundation
import CoreMedia
import Foundation
import HaishinKit

/// Finite off-network application-payload accounting using the publishing muxer.
public final class CandidateTransportMeasurement: @unchecked Sendable {
    public enum Media: String, Sendable { case video, audio }
    /// Scalar receipt in actual accepted append order; retains no media buffers.
    public struct Input: Sendable {
        public let media: Media
        public let sourcePTS: CMTime
        public let decodePTS: CMTime
        public let byteCount: Int
        public let isSync: Bool
        /// Includes one four-byte Annex-B prefix per format parameter set on sync video.
        public let parameterSetBytes: Int
    }
    public enum Outcome: String, Sendable { case completed, failed, cancelled }
    public struct Result: Sendable {
        public let inputs: [Input]
        public let outcome: Outcome
        public let failure: String?
        public let videoInputCount: Int
        public let audioInputCount: Int
        public let videoInputBytes: Int
        public let audioInputBytes: Int
        public let firstVideoPTS: CMTime?
        public let lastVideoPTS: CMTime?
        public let firstAudioPTS: CMTime?
        public let lastAudioPTS: CMTime?
        public let transportBytes: Int
        public let transportMessageCount: Int
    }
    private let lock = NSLock()
    private let writer: TSWriter
    private let tally: TransportTally
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var videoCount = 0, audioCount = 0, videoBytes = 0, audioBytes = 0
    private var firstVideo: CMTime?, lastVideo: CMTime?, firstAudio: CMTime?, lastAudio: CMTime?
    private var terminal: Result?
    private var inputs: [Input] = []

    public init() {
        let tally = TransportTally()
        self.tally = tally
        writer = TSWriter(outputSink: { tally.consume($0) })
        writer.expectedMedias = [.video, .audio]
    }

    /// Borrows ready length-prefixed H.264 with four-byte NAL lengths. Neither
    /// the sample nor its buffers may be mutated during this synchronous call.
    @discardableResult public func appendVideo(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard terminal == nil else { return false }
            guard videoCount < 121 else { return fail("videoCountLimit") }
            guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
                  sample.imageBuffer == nil, let format = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
                  let block = sample.dataBuffer else { return fail("invalidVideo") }
            let bytes = CMBlockBufferGetDataLength(block), pts = sample.presentationTimeStamp, dts = sample.decodeTimeStamp
            guard bytes > 0, bytes <= 2 * 1024 * 1024, CMSampleBufferGetTotalSampleSize(sample) == bytes else {
                return fail("videoByteLimit")
            }
            guard valid(pts), dts == .invalid || valid(dts), lastVideo.map({ CMTimeCompare($0, pts) < 0 }) ?? true else {
                return fail("invalidVideoTimestamp")
            }
            guard preflight(pts, bytes: bytes) else { return false }
            guard let parameterBytes = h264ParameterSetBytes(format), validNALUnits(block, bytes: bytes, requireIDR: videoCount == 0) else {
                return fail("invalidH264")
            }
            if let videoFormat, !CFEqual(videoFormat, format) { return fail("videoFormatChanged") }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String]
            guard notSync == nil || notSync is Bool else { return fail("invalidSyncMetadata") }
            guard videoCount != 0 || !(notSync as? Bool ?? false) else { return fail("missingInitialKeyframe") }
            writer.videoFormat = format
            writer.append(sample)
            guard checkWriter() else { return false }
            videoFormat = format; videoCount += 1; videoBytes += bytes
            firstVideo = firstVideo ?? pts; lastVideo = pts
            let isSync = !(notSync as? Bool ?? false)
            inputs.append(.init(media: .video, sourcePTS: pts, decodePTS: dts, byteCount: bytes,
                                isSync: isSync, parameterSetBytes: isSync ? parameterBytes : 0))
            return true
        }
    }

    /// Borrows exactly one AAC packet. Output is counted and discarded; no
    /// socket, output stream, timer or per-input task is created.
    @discardableResult public func appendAudio(_ buffer: AVAudioCompressedBuffer, when: AVAudioTime) -> Bool {
        lock.withLock {
            guard terminal == nil else { return false }
            guard audioCount < 512 else { return fail("audioCountLimit") }
            let bytes = Int(buffer.byteLength), format = buffer.format.formatDescription
            let asbd = buffer.format.streamDescription.pointee
            guard bytes > 0, bytes <= 8184, buffer.byteLength <= buffer.byteCapacity,
                  buffer.packetCount == 1, asbd.mFormatID == kAudioFormatMPEG4AAC,
                  asbd.mFormatFlags == 2, asbd.mFramesPerPacket == 1024,
                  asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
                  [96_000.0, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350].contains(asbd.mSampleRate),
                  (1...6).contains(asbd.mChannelsPerFrame) || asbd.mChannelsPerFrame == 8,
                  let packet = buffer.packetDescriptions?.pointee, packet.mStartOffset == 0,
                  packet.mDataByteSize == buffer.byteLength,
                  packet.mVariableFramesInPacket == 0 || packet.mVariableFramesInPacket == 1024,
                  AudioSpecificConfig(formatDescription: format) != nil else { return fail("invalidAudio") }
            guard when.isHostTimeValid else { return fail("invalidAudioTimestamp") }
            let pts = when.makeTime()
            guard valid(pts), lastAudio.map({ CMTimeCompare($0, pts) < 0 }) ?? true else { return fail("invalidAudioTimestamp") }
            guard preflight(pts, bytes: bytes) else { return false }
            if let audioFormat, !CFEqual(audioFormat, format) { return fail("audioFormatChanged") }
            writer.audioFormat = buffer.format
            writer.append(buffer, when: when)
            guard checkWriter() else { return false }
            audioFormat = format; audioCount += 1; audioBytes += bytes
            firstAudio = firstAudio ?? pts; lastAudio = pts
            inputs.append(.init(media: .audio, sourcePTS: pts, decodePTS: .invalid, byteCount: bytes,
                                isSync: true, parameterSetBytes: 0))
            return true
        }
    }

    public func finish() -> Result {
        lock.withLock {
            if let terminal { return terminal }
            writer.finishOutput()
            if !checkWriter() { return terminal! }
            guard videoCount > 0, audioCount > 0, writer.transportClock != nil, tally.bytes > 0 else {
                return complete(.failed, failure: "incompleteTracks")
            }
            return complete(.completed)
        }
    }
    public func cancel() -> Result {
        lock.withLock { terminal ?? complete(.cancelled) }
    }

    private func valid(_ pts: CMTime) -> Bool {
        pts.isNumeric && pts.timescale > 0 && pts.epoch == 0 && pts.value >= 0
    }
    private func preflight(_ pts: CMTime, bytes: Int) -> Bool {
        guard bytes <= 32 * 1024 * 1024 - videoBytes - audioBytes else { return fail("compressedInputByteLimit") }
        let low = [firstVideo, firstAudio].compactMap { $0 }.reduce(pts) { min($0, $1) }
        let high = [lastVideo, lastAudio].compactMap { $0 }.reduce(pts) { max($0, $1) }
        let span = CMTimeSubtract(high, low)
        guard span.isNumeric, CMTimeCompare(span, CMTime(value: 17, timescale: 4)) <= 0 else { return fail("sourceSpanLimit") }
        return true
    }
    private func checkWriter() -> Bool {
        if tally.rejected { return fail("transportOutputRejected") }
        if let error = writer.error { return fail("muxer:\(error)") }
        if let error = writer.failure.error { return fail("muxer:\(error)") }
        return true
    }
    private func fail(_ reason: String) -> Bool {
        _ = complete(.failed, failure: reason)
        return false
    }
    private func complete(_ outcome: Outcome, failure: String? = nil) -> Result {
        if let terminal { return terminal }
        let result = Result(inputs: inputs, outcome: outcome, failure: failure, videoInputCount: videoCount, audioInputCount: audioCount,
            videoInputBytes: videoBytes, audioInputBytes: audioBytes, firstVideoPTS: firstVideo, lastVideoPTS: lastVideo,
            firstAudioPTS: firstAudio, lastAudioPTS: lastAudio, transportBytes: tally.bytes, transportMessageCount: tally.messages)
        terminal = result
        writer.clear(); writer.failure.finish()
        videoFormat = nil; audioFormat = nil; inputs.removeAll(keepingCapacity: false)
        return result
    }

    // Validate bounded format metadata and all AVCC lengths before the muxer
    // copies payloads. Its production converter expects exactly four bytes.
    private func h264ParameterSetBytes(_ format: CMFormatDescription) -> Int? {
        var count = 0, headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength) == noErr, headerLength == 4, count >= 2, count <= 16 else { return nil }
        var total = 0, hasSPS = false, hasPPS = false
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?, size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr, let pointer, size > 0, size <= 64 * 1024 - total else { return nil }
            total += size
            if pointer.pointee & 0x1f == 7 { hasSPS = true }
            if pointer.pointee & 0x1f == 8 { hasPPS = true }
        }
        return hasSPS && hasPPS ? total + count * 4 : nil
    }
    private func validNALUnits(_ block: CMBlockBuffer, bytes: Int, requireIDR: Bool) -> Bool {
        var offset = 0, hasVCL = false, hasIDR = false
        while offset < bytes {
            guard bytes - offset >= 4 else { return false }
            var encodedLength: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: 4, destination: &encodedLength) == noErr else { return false }
            let length = Int(UInt32(bigEndian: encodedLength))
            offset += 4
            guard length > 0, length <= bytes - offset else { return false }
            var header: UInt8 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: 1, destination: &header) == noErr,
                  header & 0x80 == 0, (1...23).contains(header & 0x1f) else { return false }
            let type = header & 0x1f
            if (1...5).contains(type) { hasVCL = true }
            if type == 5 { hasIDR = true }
            offset += length
        }
        return offset == bytes && hasVCL && (!requireIDR || hasIDR)
    }
}

/// Access is serialized by the measurement lock, including the writer's sink.
private final class TransportTally {
    var bytes = 0, messages = 0
    var rejected = false
    func consume(_ data: Data) -> Bool {
        guard !rejected, !data.isEmpty, data.count % 188 == 0 else { rejected = true; return false }
        let (total, byteOverflow) = bytes.addingReportingOverflow(data.count)
        let chunks = data.count / SRTSocket.payloadSize + (data.count % SRTSocket.payloadSize == 0 ? 0 : 1)
        let (count, countOverflow) = messages.addingReportingOverflow(chunks)
        guard !byteOverflow, !countOverflow else { rejected = true; return false }
        bytes = total; messages = count
        return true
    }
}
