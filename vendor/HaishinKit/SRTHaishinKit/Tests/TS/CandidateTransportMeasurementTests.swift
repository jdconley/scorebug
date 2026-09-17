import AVFoundation
import CoreMedia
import HaishinKit
import Testing
import VideoToolbox
@testable import SRTHaishinKit

@Suite(.serialized) struct CandidateTransportMeasurementTests {
    @Test(arguments: [6, 161, 162, 163, 1270, 1316, 2632, 8184])
    func matchesActualMuxWritesAndIndependentSRTChunkRounding(payloadBytes: Int) async throws {
        let measurement = CandidateTransportMeasurement(), writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.video, .audio]
        var expectedVideoBytes = 0, expectedAudioBytes = 0
        for (index, seconds) in [10.0, 10.5, 12.1, 13, 14].enumerated() {
            let a = audio(bytes: min(payloadBytes, 8184)), v = try video(seconds, bytes: payloadBytes, sync: index % 2 == 0)
            writer.audioFormat = a.format; writer.append(a, when: time(seconds))
            writer.videoFormat = v.formatDescription; writer.append(v)
            #expect(measurement.appendAudio(a, when: time(seconds)))
            #expect(measurement.appendVideo(v))
            expectedAudioBytes += Int(a.byteLength); expectedVideoBytes += CMSampleBufferGetTotalSampleSize(v)
        }
        writer.finishOutput()
        #expect(writer.error == nil)
        var writes: [Data] = []
        for await data in output { writes.append(data) }
        let result = measurement.finish()
        #expect(result.outcome == .completed && result.failure == nil)
        #expect(result.videoInputCount == 5 && result.audioInputCount == 5)
        #expect(result.videoInputBytes == expectedVideoBytes && result.audioInputBytes == expectedAudioBytes)
        #expect(result.firstVideoPTS == CMTime(seconds: 10, preferredTimescale: 48_000))
        #expect(result.lastVideoPTS == CMTime(seconds: 14, preferredTimescale: 48_000))
        #expect(result.firstAudioPTS == time(10).makeTime() && result.lastAudioPTS == time(14).makeTime())
        #expect(result.transportBytes == writes.reduce(0) { $0 + $1.count })
        #expect(result.transportMessageCount == writes.reduce(0) { $0 + ($1.count + 1315) / 1316 })
        #expect(result.transportMessageCount > (result.transportBytes + 1315) / 1316)
        #expect(result.transportBytes > result.videoInputBytes + result.audioInputBytes)
        #expect(writes.allSatisfy { !$0.isEmpty && $0.count % 188 == 0 })
        let bytes = writes.reduce(into: Data()) { $0.append($1) }
        let pids = stride(from: 0, to: bytes.count, by: 188).map { (UInt16(bytes[$0 + 1] & 0x1f) << 8) | UInt16(bytes[$0 + 2]) }
        #expect(pids.filter { $0 == TSWriter.defaultPATPID }.count >= 2)
        #expect(pids.filter { $0 == TSWriter.defaultPMTPID }.count >= 2)
        #expect(pids.contains(TSWriter.defaultVideoPID) && pids.contains(TSWriter.defaultAudioPID))
        #expect(bytes.range(of: Data([0, 0, 0, 1, 103, 77, 64, 13])) != nil)
        #expect(bytes.range(of: Data([0xff, 0xf9])) != nil)
    }

    @Test func synchronousSinkDiscardsWithoutOutputQueueAndPropagatesRejection() throws {
        var writes = 0
        let writer = TSWriter(outputSink: { data in writes += 1; return data.count % 188 == 0 })
        writer.expectedMedias = [.video, .audio]
        let a = audio(), v = try video(10)
        writer.audioFormat = a.format; writer.videoFormat = v.formatDescription
        writer.append(a, when: time(10)); writer.append(v); writer.finishOutput()
        #expect(writes >= 3 && writer.error == nil && writer.pendingOutputCount == 0)
        let rejected = TSWriter(outputSink: { _ in false })
        rejected.expectedMedias = [.video, .audio]
        rejected.audioFormat = a.format; rejected.videoFormat = v.formatDescription
        rejected.append(a, when: time(10)); rejected.append(v)
        #expect(rejected.error == .outputQueueLimitExceeded)
        let oversized = TSWriter(outputLimits: .init(count: 32, bytesPerItem: 1), outputSink: { _ in true })
        oversized.expectedMedias = [.video, .audio]
        oversized.audioFormat = a.format; oversized.videoFormat = v.formatDescription
        oversized.append(a, when: time(10)); oversized.append(v)
        #expect(oversized.error == .outputByteLimitExceeded)
    }

    @Test func terminalResultsAreIdempotentAndBothTracksAreRequired() throws {
        let empty = CandidateTransportMeasurement()
        #expect(empty.finish().outcome == .failed)
        let missing = CandidateTransportMeasurement()
        #expect(missing.appendVideo(try video(10)))
        #expect(missing.finish().outcome == .failed)
        let cancelled = CandidateTransportMeasurement()
        #expect(cancelled.appendAudio(audio(), when: time(10)))
        #expect(cancelled.cancel().outcome == .cancelled)
        #expect(cancelled.finish().outcome == .cancelled)
        #expect(!cancelled.appendVideo(try video(10)))
        let complete = CandidateTransportMeasurement()
        #expect(complete.appendVideo(try video(10)))
        #expect(complete.appendAudio(audio(), when: time(10)))
        let first = complete.finish(), repeated = complete.cancel()
        #expect(first.outcome == .completed && repeated.outcome == .completed)
        #expect(first.transportBytes == repeated.transportBytes && first.transportMessageCount == repeated.transportMessageCount)
        #expect(!complete.appendAudio(audio(), when: time(10.1)))
    }

    @Test(arguments: [UInt8(0x41), UInt8(0x06)])
    func syncMetadataCannotSubstituteForInitialIDRSlice(header: UInt8) throws {
        let measurement = CandidateTransportMeasurement()
        #expect(measurement.appendAudio(audio(), when: time(10)))
        let misleadingSync = try video(10, payload: [0, 0, 0, 1, header])
        #expect(!misleadingSync.isNotSync)
        #expect(!measurement.appendVideo(misleadingSync))
        #expect(measurement.finish().outcome == .failed)
    }

    @Test func nonVCLOnlyOutputIsNotACompleteVideoFrameAfterStartup() throws {
        let measurement = CandidateTransportMeasurement()
        #expect(measurement.appendAudio(audio(), when: time(10)))
        #expect(measurement.appendVideo(try video(10)))
        #expect(!measurement.appendVideo(try video(10.1, sync: false, payload: [0, 0, 0, 1, 0x06])))
        #expect(measurement.finish().outcome == .failed)
    }

    @Test func initialIDRMayIncludeNonVCLHeadersAlongsideItsSlice() throws {
        let measurement = CandidateTransportMeasurement()
        #expect(measurement.appendAudio(audio(), when: time(10)))
        #expect(measurement.appendVideo(try video(10, payload: [0, 0, 0, 1, 0x06, 0, 0, 0, 1, 0x65])))
        #expect(measurement.finish().outcome == .completed)
    }

    @Test(arguments: ["notReady", "codec", "format", "noParameters", "headerLength", "negative", "epoch", "invalidPTS", "duplicate", "backward", "span", "noKeyframe", "truncatedNAL", "zeroNAL", "oversizedNAL", "trailingNAL", "zeroBytes", "oversizedBytes"])
    func rejectsMalformedVideo(fault: String) throws {
        let measurement = CandidateTransportMeasurement()
        if ["format", "duplicate", "backward", "span"].contains(fault) {
            #expect(measurement.appendAudio(audio(), when: time(10)))
            #expect(measurement.appendVideo(try video(10)))
        }
        var sample = try video(fault == "backward" ? 9 : fault == "span" ? 14.3 : fault == "duplicate" ? 10 : 10.1,
            bytes: fault == "oversizedBytes" ? 2 * 1024 * 1024 + 1 : 6,
            sync: fault != "noKeyframe", headerLength: fault == "headerLength" ? 2 : 4,
            alternateFormat: fault == "format", noParameters: fault == "noParameters", wrongCodec: fault == "codec")
        if fault == "notReady" { CMSampleBufferInvalidate(sample) }
        if ["negative", "epoch", "invalidPTS"].contains(fault) {
            let pts = fault == "negative" ? CMTime(value: -1, timescale: 30)
                : fault == "epoch" ? CMTime(value: 1, timescale: 30, flags: .valid, epoch: 1) : .invalid
            sample = try retime(sample, pts: pts)
        }
        if ["truncatedNAL", "zeroNAL", "oversizedNAL", "trailingNAL", "zeroBytes"].contains(fault) {
            let bytes: [UInt8] = fault == "truncatedNAL" ? [0, 0, 0] : fault == "zeroNAL" ? [0, 0, 0, 0]
                : fault == "oversizedNAL" ? [0, 0, 0, 9, 0x65] : fault == "trailingNAL" ? [0, 0, 0, 1, 0x65, 0] : []
            sample = try video(10, payload: bytes)
        }
        #expect(!measurement.appendVideo(sample))
        #expect(measurement.finish().outcome == .failed)
        #expect(!measurement.appendAudio(audio(), when: time(10.2)))
    }

    @Test(arguments: ["packets", "zero", "oversize", "packetOffset", "packetSize", "codec", "noHost", "duplicate", "backward", "format", "span", "profile", "fractionalRate", "packetFrames"])
    func rejectsMalformedAudio(fault: String) throws {
        let measurement = CandidateTransportMeasurement()
        #expect(measurement.appendVideo(try video(10)))
        if ["duplicate", "backward", "format"].contains(fault) { #expect(measurement.appendAudio(audio(), when: time(10))) }
        let buffer = audio(bytes: fault == "oversize" ? 8185 : 4,
            sampleRate: fault == "format" ? 44_100 : fault == "fractionalRate" ? 48_000.5 : 48_000,
            codec: fault == "codec" ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            flags: fault == "profile" ? 5 : 2, framesPerPacket: fault == "packetFrames" ? 2048 : 1024)
        if fault == "packets" { buffer.packetCount = 2 }
        if fault == "zero" { buffer.byteLength = 0 }
        if fault == "packetOffset" { buffer.packetDescriptions?.pointee.mStartOffset = 1 }
        if fault == "packetSize" { buffer.packetDescriptions?.pointee.mDataByteSize = 3 }
        let when = fault == "noHost" ? AVAudioTime(sampleTime: 0, atRate: 48_000)
            : time(fault == "backward" ? 9.9 : fault == "duplicate" ? 10 : fault == "span" ? 14.3 : 10.1)
        #expect(!measurement.appendAudio(buffer, when: when))
        #expect(measurement.finish().outcome == .failed)
    }

    @Test func independentVideoAudioAndAggregateInputLimits() throws {
        let v = CandidateTransportMeasurement()
        #expect(v.appendAudio(audio(), when: time(10)))
        for i in 0..<121 { try #require(v.appendVideo(try video(10 + Double(i) / 30))) }
        #expect(!v.appendVideo(try video(10 + 121.0 / 30)))
        #expect(v.finish().failure == "videoCountLimit")
        let a = CandidateTransportMeasurement()
        #expect(a.appendVideo(try video(10)))
        for i in 0..<512 { try #require(a.appendAudio(audio(), when: time(10 + Double(i) / 480))) }
        #expect(!a.appendAudio(audio(), when: time(10 + 512.0 / 480)))
        #expect(a.finish().failure == "audioCountLimit")
        let bytes = CandidateTransportMeasurement()
        #expect(bytes.appendAudio(audio(), when: time(10)))
        for i in 0..<31 { try #require(bytes.appendVideo(try video(10 + Double(i) / 30, bytes: 1024 * 1024))) }
        #expect(!bytes.appendVideo(try video(10 + 31.0 / 30, bytes: 1024 * 1024)))
        #expect(bytes.finish().failure == "compressedInputByteLimit")
    }

    @Test func startupPacketByteAndTimeBoundsRemainEnforced() throws {
        let packets = CandidateTransportMeasurement()
        for i in 0..<256 { try #require(packets.appendAudio(audio(), when: time(10 + Double(i) / 48_000))) }
        #expect(!packets.appendAudio(audio(), when: time(10 + 256.0 / 48_000)))
        #expect(packets.finish().failure?.contains("startupPacketLimitExceeded") == true)
        let bytes = CandidateTransportMeasurement()
        for i in 0..<7 { try #require(bytes.appendVideo(try video(10 + Double(i) / 30, bytes: 1024 * 1024))) }
        #expect(!bytes.appendVideo(try video(10 + 7.0 / 30, bytes: 1024 * 1024)))
        #expect(bytes.finish().failure?.contains("startupByteLimitExceeded") == true)
        let clock = CandidateTransportMeasurement()
        #expect(clock.appendVideo(try video(10)))
        #expect(!clock.appendVideo(try video(12.1)))
        #expect(clock.finish().failure?.contains("startupTimeLimitExceeded") == true)
    }

    @Test func realCandidateEncoderFeedsActualH264ToTheSameMuxer() async throws {
        let measurement = CandidateTransportMeasurement()
        let settings = VideoCodecSettings(videoSize: CGSize(width: 32, height: 32), bitRate: 500_000,
            profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String, allowFrameReordering: false)
        let encoder = try VideoCandidateEncoder(settings: settings, compressedOutputConsumer: { measurement.appendVideo($0) })
        try await encoder.start()
        do {
            for i in 0..<3 {
                try #require(measurement.appendAudio(audio(), when: time(10 + Double(i) / 48)))
                try #require(encoder.offer(try raw(10 + Double(i) / 30)))
            }
            let encoded = await encoder.finish(), result = measurement.finish()
            #expect(encoded.outcome == .completed && encoded.frames.count == 3)
            #expect(result.outcome == .completed && result.videoInputCount == 3 && result.audioInputCount == 3)
            #expect(result.videoInputBytes == encoded.frames.reduce(0) { $0 + $1.byteCount })
            #expect(result.transportBytes > result.videoInputBytes + result.audioInputBytes)
            #expect(result.transportMessageCount > 0 && result.transportMessageCount <= result.transportBytes)
        } catch {
            _ = await encoder.cancel(); _ = measurement.cancel(); throw error
        }
    }

    private func time(_ seconds: Double) -> AVAudioTime { .init(hostTime: AVAudioTime.hostTime(forSeconds: seconds)) }
    private func audio(bytes: Int = 4, sampleRate: Double = 48_000, codec: AudioFormatID = kAudioFormatMPEG4AAC,
                       flags: UInt32 = 2, framesPerPacket: UInt32 = 1024) -> AVAudioCompressedBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: codec, mFormatFlags: flags,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let buffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &asbd)!, packetCapacity: 2, maximumPacketSize: max(bytes, 1))
        buffer.byteLength = UInt32(bytes); buffer.packetCount = 1
        buffer.data.initializeMemory(as: UInt8.self, repeating: 42, count: bytes)
        buffer.packetDescriptions?.pointee = .init(mStartOffset: 0, mVariableFramesInPacket: framesPerPacket, mDataByteSize: UInt32(bytes))
        return buffer
    }
    private func video(_ seconds: Double, bytes: Int = 6, sync: Bool = true, payload: [UInt8]? = nil,
                       headerLength: Int32 = 4, alternateFormat: Bool = false, noParameters: Bool = false, wrongCodec: Bool = false) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        if noParameters || wrongCodec {
            #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: wrongCodec ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                width: 16, height: 16, extensions: nil, formatDescriptionOut: &format) == noErr)
        } else {
            let sps: [UInt8] = [103, 77, 64, 13, 218, 5, 7, 236, 4, 64, 0, 0, 3, 0, 64, 0, 0, 7, 131, 197, 10, 168]
            let pps: [UInt8] = alternateFormat ? [104, 238, 60, 128] : [104, 239, 60, 128]
            let status = sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: [s.baseAddress!, p.baseAddress!], parameterSetSizes: [s.count, p.count],
                    nalUnitHeaderLength: headerLength, formatDescriptionOut: &format)
            } }
            #expect(status == noErr)
        }
        var data = payload ?? Array(repeating: UInt8(0x7a), count: bytes)
        if payload == nil {
            let length = UInt32(bytes - 4)
            data[0] = UInt8((length >> 24) & 255); data[1] = UInt8((length >> 16) & 255)
            data[2] = UInt8((length >> 8) & 255); data[3] = UInt8(length & 255); data[4] = sync ? 0x65 : 0x41
        }
        var block: CMBlockBuffer?
        if !data.isEmpty {
            #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr)
            data.withUnsafeBytes { raw in #expect(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: data.count) == noErr) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var size = data.count, sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        let result = try #require(sample); result.isNotSync = !sync; return result
    }
    private func retime(_ sample: CMSampleBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result) == noErr)
        return try #require(result)
    }
    private func raw(_ seconds: Double) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let pixel = try #require(image)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let resolved = try #require(format)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: resolved, sampleTiming: &timing, sampleBufferOut: &result) == noErr)
        return try #require(result)
    }
}
