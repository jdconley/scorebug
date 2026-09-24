import AVFoundation
import CoreMedia
import HaishinKit
import Testing
@testable import SRTHaishinKit

@Suite struct TSWriterStartupTests {
    @Test func compressedSRTPassthroughDoesNotNotifyEncoderObserver() async throws {
        let bytes = PassthroughTransport()
        let connection = SRTConnection(socket: SRTSocket(sender: { bytes.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection, encoderCompletionObserver: { _, _ in
            Issue.record("Compressed passthrough must never report native encoding")
        })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        await stream.append(try video(0))
        await stream.finish()
        #expect(await stream.publishingError == nil)
        #expect(bytes.count > 0, "Compressed media must still reach the transport")
        await connection.close()
    }

    @Test func muxObserverWaitsForBothTracksAndReportsAcceptedSourceAndTransportTimes() async throws {
        let writer = TSWriter()
        let output = writer.output
        var observed: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { observed.append($0) }
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        writer.audioFormat = a.format
        let firstAudio = time(10)
        writer.append(a, when: firstAudio)
        writer.append(a, when: time(10.125))
        #expect(observed.isEmpty, "Startup buffering is not output admission")
        let v = try video(10.5, dts: CMTime(value: 41, timescale: 4))
        writer.videoFormat = v.formatDescription
        writer.append(v)
        #expect(writer.error == nil)
        #expect(observed.map { $0.media.rawValue } == ["audio", "audio", "video"])
        let first = try #require(observed.first), last = try #require(observed.last)
        let clock = try #require(writer.transportClock)
        #expect(first.sourcePTS == firstAudio.makeTime())
        #expect(first.sourceDTS == .invalid)
        #expect(first.transportPTS == UInt64(try #require(clock.presentationTimestamp(for: first.sourcePTS))))
        #expect(first.transportDTS == nil)
        #expect(last.sourcePTS == v.presentationTimeStamp)
        #expect(last.sourceDTS == v.decodeTimeStamp)
        #expect(last.transportPTS == UInt64(try #require(clock.presentationTimestamp(for: v.presentationTimeStamp))))
        #expect(last.transportDTS == UInt64(try #require(clock.presentationTimestamp(for: v.decodeTimeStamp))))
        #expect(observed.allSatisfy { $0.observedAt.isFinite && $0.observedAt >= 0 })
        writer.finishOutput()
        let emitted = await packets(output).filter {
            $0.payloadUnitStartIndicator && [TSWriter.defaultAudioPID, TSWriter.defaultVideoPID].contains($0.pid)
        }
        #expect(emitted.map { UInt64(pts($0)) } == observed.map { $0.transportPTS })
    }

    @Test(arguments: ["absent", "rejectedSink", "fullQueue", "oversizedOutput"])
    func muxObserverNeverReportsUnacceptedOutput(mode: String) throws {
        var writes = 0
        let writer = TSWriter(outputLimits: .init(count: mode == "fullQueue" ? 1 : 32,
            bytesPerItem: mode == "oversizedOutput" ? 1 : 4096),
            outputSink: mode == "rejectedSink" ? { _ in writes += 1; return writes == 1 } : nil)
        var observed: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { observed.append($0) }
        let output = mode == "fullQueue" || mode == "oversizedOutput" ? writer.output : nil
        writer.expectedMedias = [.video]
        let v = try video(10)
        writer.videoFormat = v.formatDescription
        writer.append(v)
        #expect(observed.isEmpty)
        #expect(mode == "absent" ? writer.error == nil : writer.error != nil)
        withExtendedLifetime(output) {}
    }

    @Test func muxObserverFollowsSuccessfulSinkWritesAndClearRetiresOldObserver() throws {
        var writes = 0, callsAtWrite: [Int] = []
        let writer = TSWriter(outputSink: { _ in writes += 1; return true })
        writer.muxedPacketObserver = { _ in callsAtWrite.append(writes) }
        writer.expectedMedias = [.video]
        let first = try video(10)
        writer.videoFormat = first.formatDescription
        writer.append(first)
        #expect(callsAtWrite == [2], "PAT/PMT is not a PES observation")
        writer.clear()
        writer.expectedMedias = [.video]
        let second = try video(100)
        writer.videoFormat = second.formatDescription
        writer.append(second)
        #expect(callsAtWrite == [2])
        var secondRows: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { secondRows.append($0) }
        writer.append(try video(100.5))
        #expect(secondRows.map { $0.transportPTS } == [54_000])
    }

    @Test func streamMuxObserverCapturesEachPublishingGenerationThroughFinalDrain() async throws {
        let observed = StartupMuxFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, muxedPacketObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio, .video]); await stream.publish()
        let firstGeneration = try #require(await stream.publishingGeneration)
        await stream.append(audio(), when: time(10))
        #expect(observed.rows.isEmpty)
        await stream.append(try video(10.25))
        await stream.finish()
        #expect(observed.rows.count == 2)
        #expect(observed.rows.allSatisfy { $0.publishingGeneration == firstGeneration })
        await stream.setExpectedMedias([.video]); await stream.publish()
        let secondGeneration = try #require(await stream.publishingGeneration)
        #expect(secondGeneration != firstGeneration)
        await stream.append(try video(100))
        await stream.finish()
        #expect(observed.rows.count == 3)
        #expect(observed.rows.last?.publishingGeneration == secondGeneration)
        #expect(observed.rows.last?.transportPTS == 9_000)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test func transportSendObserverPairsAttemptsAcrossPublishingGenerations() async throws {
        let observed = TransportSendFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, transportSendObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        var generations: [UInt64] = []
        for origin in [10.0, 100.0] {
            await stream.setExpectedMedias([.audio]); await stream.publish()
            generations.append(try #require(await stream.publishingGeneration))
            await stream.append(audio(), when: time(origin))
            await stream.finish()
        }
        let rows = observed.rows
        #expect(!rows.isEmpty)
        #expect(Set(rows.map(\.publishingGeneration)) == Set(generations))
        for generation in generations {
            let own = rows.filter { $0.publishingGeneration == generation }
            #expect(own.count >= 8 && own.count.isMultiple(of: 4))
            for index in stride(from: 0, to: own.count - 3, by: 4) {
                let start = own[index], socketStart = own[index + 1], socketEnd = own[index + 2], end = own[index + 3]
                #expect(start.phase == .started && end.phase == .returned)
                #expect(start.sequence == UInt64(index / 4 + 1) && end.sequence == start.sequence)
                #expect(socketStart.phase == .socketStarted && socketEnd.phase == .socketReturned)
                #expect([socketStart, socketEnd].allSatisfy { $0.sequence == start.sequence && $0.byteCount == start.byteCount })
                #expect(start.observedAt <= socketStart.observedAt && socketStart.observedAt <= socketEnd.observedAt && socketEnd.observedAt <= end.observedAt)
                #expect(start.byteCount > 0 && end.byteCount == start.byteCount)
                #expect(start.pendingPacketCount >= 0 && end.pendingPacketCount >= 0)
                #expect(start.observedAt.isFinite && start.observedAt <= end.observedAt)
            }
        }
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test func transportSendReturnDoesNotMeanFailedWriteSucceeded() async throws {
        let observed = TransportSendFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { _ in -1 }))
        let stream = SRTStream(connection: connection, transportSendObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio]); await stream.publish()
        await stream.append(audio(), when: time(10))
        await stream.finish()
        let rows = observed.rows
        #expect(rows.count == 4)
        #expect(rows.map(\.phase) == [.started, .socketStarted, .socketReturned, .returned])
        #expect(rows.first?.phase == .started && rows.last?.phase == .returned)
        #expect(rows.first?.sequence == rows.last?.sequence)
        #expect(await connection.publishingError == .transportWriteFailed)
        await connection.close()
    }

    @Test func socketSendObserverIsAbsentForDisconnectedAndStaleGuards() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        await connection.send(Data([1]), generation: 0, socketSendObserver: { _ in
            Issue.record("Disconnected calls do not enter the socket")
        })
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        let session = try #require(await connection.publishingSession())
        await connection.close()
        await connection.send(Data([1]), generation: session, socketSendObserver: { _ in
            Issue.record("Stale calls do not enter the socket")
        })
    }

    private func audio(_ marker: UInt8 = 42) -> AVAudioCompressedBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let format = AVAudioFormat(streamDescription: &description)!
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 4)
        buffer.byteLength = 4
        buffer.packetCount = 1
        buffer.data.initializeMemory(as: UInt8.self, repeating: marker, count: 4)
        buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: 4)
        return buffer
    }

    private func time(_ seconds: Double) -> AVAudioTime {
        AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))
    }

    private func video(_ seconds: Double, dts: CMTime = .invalid, payloadBytes: Int = 6) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 16, height: 16, extensions: nil, formatDescriptionOut: &format) == noErr)
        let bytes: [UInt8] = [0, 0, 0, 2, 0x65, 0x7a] + Array(repeating: 0, count: payloadBytes - 6)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr)
        bytes.withUnsafeBytes { raw in
            #expect(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: dts)
        var size = bytes.count
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func retimedVideo(_ pts: CMTime) throws -> CMSampleBuffer {
        let source = try video(0)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: source, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &copy) == noErr)
        return try #require(copy)
    }

    @Test func pcrCadenceUsesExactRelativeTicksAtLargeAbsoluteClocks() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.video]
        let base = Int64.max - 10_000
        for milliseconds: Int64 in [0, 19, 20, 39, 40] {
            let sample = try retimedVideo(CMTime(value: base + milliseconds, timescale: 1_000))
            writer.videoFormat = sample.formatDescription
            writer.append(sample)
        }
        #expect(writer.error == nil)
        writer.clear()
        let result = await packets(output)
        let video = result.filter { $0.pid == TSWriter.defaultVideoPID && $0.payloadUnitStartIndicator }
        #expect(video.map { pts($0) } == [9_000, 10_710, 10_800, 12_510, 12_600])
        let references = video.compactMap { packet -> UInt64? in
            guard let field = packet.adaptationField, field.pcrFlag else { return nil }
            let b = field.pcr
            return UInt64(b[0]) << 25 | UInt64(b[1]) << 17 | UInt64(b[2]) << 9 |
                UInt64(b[3]) << 1 | UInt64(b[4]) >> 7
        }
        #expect(references == [1_800, 3_600])
    }

    @Test func emittedWrapBitsMatchTheSelectedClock() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.video]
        #expect(writer.transportClock == nil)
        let values: [Int64] = [0, 8_589_925_592, 8_589_928_592]
        for value in values {
            let sample = try retimedVideo(CMTime(value: value, timescale: 90_000))
            writer.videoFormat = sample.formatDescription
            writer.append(sample)
        }
        let clock = try #require(writer.transportClock)
        #expect(clock.origin == .zero)
        #expect(clock.presentationTimestamp(for: CMTime(value: values[1], timescale: 90_000)) == 8_589_934_592)
        #expect(writer.error == nil)
        writer.finishOutput()
        #expect(writer.transportClock == clock)
        let video = await packets(output).filter { $0.pid == TSWriter.defaultVideoPID && $0.payloadUnitStartIndicator }
        #expect(video.map { pts($0) } == [9_000, 0, 3_000])
        #expect(video.allSatisfy { $0.payload[9] >> 4 == 2 })
        writer.clear()
        #expect(writer.transportClock == nil)
    }

    @Test func unrepresentablePresentationTimeFailsBeforePayloadEmission() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.video]
        let first = try retimedVideo(.zero)
        writer.videoFormat = first.formatDescription
        writer.append(first)
        writer.append(try retimedVideo(CMTime(value: Int64.max, timescale: 90_000)))
        #expect(writer.error == .invalidTimestamp)
        let video = await packets(output).filter { $0.pid == TSWriter.defaultVideoPID && $0.payloadUnitStartIndicator }
        #expect(video.count == 1)
        #expect(video.map { pts($0) } == [9_000])
    }

    @Test func streamClockSnapshotIsScopedAndAbsentBeforeStartupOrAfterFailure() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        #expect(await stream.transportClockSnapshot == nil)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio, .video])
        await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        #expect(await stream.transportClockSnapshot == nil)
        await stream.append(try video(10.25, dts: CMTime(value: 10, timescale: 1)))
        #expect(await stream.transportClockSnapshot == nil)
        await stream.append(audio(), when: time(10.1))
        let first = try #require(await stream.transportClockSnapshot)
        #expect(first.publishingGeneration == generation)
        #expect(first.clock.origin == CMTime(value: 10, timescale: 1))
        #expect(first.clock.presentationTimestamp(for: CMTime(value: 41, timescale: 4)) == 31_500)
        // Reuse requires a graceful drain: aborting an in-flight socket send is
        // terminal for the connection, even when the muxer has selected a clock.
        await stream.finish()
        #expect(await stream.publishingError == nil)
        #expect(await stream.transportClockSnapshot == nil)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.transportClockSnapshot == nil)
        await stream.append(try video(123.25))
        let second = try #require(await stream.transportClockSnapshot)
        #expect(second.publishingGeneration != generation)
        #expect(second.clock.origin == CMTime(value: 493, timescale: 4))
        #expect(first.clock.origin == CMTime(value: 10, timescale: 1))
        await stream.append(try retimedVideo(.indefinite))
        #expect(await stream.muxerError == .invalidTimestamp)
        #expect(await stream.transportClockSnapshot == nil)
        await connection.close()
    }

    private func packets(_ stream: AsyncStream<Data>) async -> [TSPacket] {
        var result: [TSPacket] = []
        for await bytes in stream {
            for offset in stride(from: 0, to: bytes.count, by: 188) {
                if let packet = TSPacket(data: bytes.subdata(in: offset..<(offset + 188))) { result.append(packet) }
            }
        }
        return result
    }

    // Independent MPEG PES timestamp decoder: do not mirror the SDK decoder.
    private func pts(_ packet: TSPacket, offset: Int = 9) -> Int64 {
        let b = Array(packet.payload.dropFirst(offset).prefix(5))
        return Int64(b[0] & 14) << 29 | Int64(b[1]) << 22 | Int64(b[2] & 254) << 14 | Int64(b[3]) << 7 | Int64(b[4]) >> 1
    }

    @Test func retainsEveryEarlyAudioPacketAndCommonOrigin() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        writer.audioFormat = a.format
        for index in 0..<5 {
            a.data.storeBytes(of: UInt8(index + 1), as: UInt8.self)
            writer.append(a, when: time(10 + Double(index) * 1024 / 48_000))
        }
        let v = try video(10.125)
        writer.videoFormat = v.formatDescription
        writer.append(v)
        writer.clear()
        let result = await packets(output)
        let audioPackets = result.filter { $0.pid == TSWriter.defaultAudioPID && $0.payloadUnitStartIndicator }
        let videoPackets = result.filter { $0.pid == TSWriter.defaultVideoPID && $0.payloadUnitStartIndicator }
        #expect(audioPackets.count == 5)
        #expect(audioPackets.map { $0.payload[21] } == [1, 2, 3, 4, 5])
        if let first = audioPackets.first, let video = videoPackets.first {
            #expect(abs(pts(first) - 9000) <= 1)
            #expect(abs(pts(video) - pts(first) - 11_250) <= 1)
        }
    }

    @Test func waitsForPayloadAfterBothFormatsAndPreservesVideoFirstOffset() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        let v = try video(10.25)
        writer.audioFormat = a.format
        writer.videoFormat = v.formatDescription
        writer.append(v)
        var replacement: UInt8 = 0x33
        #expect(CMBlockBufferReplaceDataBytes(with: &replacement, blockBuffer: v.dataBuffer!,
            offsetIntoDestination: 5, dataLength: 1) == noErr)
        writer.append(a, when: time(10))
        writer.clear()
        let result = await packets(output).filter { $0.payloadUnitStartIndicator }
        let ap = try #require(result.first { $0.pid == TSWriter.defaultAudioPID })
        let vp = try #require(result.first { $0.pid == TSWriter.defaultVideoPID })
        #expect(abs(pts(ap) - 9000) <= 1)
        #expect(abs(pts(vp) - pts(ap) - 22_500) <= 1)
        #expect(vp.payload.last == 0x7a)
    }

    @Test func boundedStartupFailuresAreLatchedAndEmitNothing() async throws {
        let cases: [(TSWriter.StartupLimits, SRTStream.MuxerError, Double)] = [
            (.init(packetCount: 1), .startupPacketLimitExceeded, 10),
            (.init(byteCount: 30), .startupByteLimitExceeded, 10),
            (.init(mediaSpan: 2), .startupTimeLimitExceeded, 12.001)
        ]
        for (limits, failure, secondTime) in cases {
            let writer = TSWriter(startupLimits: limits)
            let output = writer.output
            writer.expectedMedias = [.audio, .video]
            let a = audio()
            writer.audioFormat = a.format
            writer.append(a, when: time(10))
            #expect(writer.error == nil)
            writer.append(a, when: time(secondTime))
            #expect(writer.error == failure)
            let v = try video(10)
            writer.videoFormat = v.formatDescription
            writer.append(v)
            #expect(writer.error == failure)
            #expect(await packets(output).isEmpty)
        }
    }

    @Test func invalidTimestampsFailExplicitly() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        writer.audioFormat = a.format
        writer.append(a, when: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(writer.error == .invalidTimestamp)
        #expect(await packets(output).isEmpty)

        writer.clear()
        let output2 = writer.output
        let v = try video(10, dts: .indefinite)
        writer.expectedMedias = [.video]
        writer.videoFormat = v.formatDescription
        writer.append(v)
        #expect(writer.error == .invalidTimestamp)
        #expect(await packets(output2).isEmpty)
    }

    @Test func singleTrackModesStartAndClearResetsFailureAndProgram() async throws {
        let writer = TSWriter(startupLimits: .init(packetCount: 1))
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        writer.audioFormat = a.format
        writer.append(a, when: time(10))
        writer.append(a, when: time(10))
        #expect(writer.error == .startupPacketLimitExceeded)
        writer.clear()
        #expect(writer.error == nil)
        #expect(writer.pmt.elementaryStreamSpecificData.isEmpty)
        for media in [AVMediaType.audio, .video] {
            let output = writer.output
            writer.expectedMedias = [media]
            if media == .audio {
                writer.audioFormat = a.format
                writer.audioFormat = nil
                writer.audioFormat = a.format
                writer.append(a, when: time(40))
                #expect(writer.pmt.PCRPID == TSWriter.defaultAudioPID)
            } else {
                let v = try video(40)
                writer.videoFormat = v.formatDescription
                writer.videoFormat = nil
                writer.videoFormat = v.formatDescription
                writer.append(v)
            }
            #expect(writer.pmt.elementaryStreamSpecificData.count == 1)
            writer.clear()
            let result = await packets(output)
            let packet = try #require(result.first { $0.pid == (media == .audio ? TSWriter.defaultAudioPID : TSWriter.defaultVideoPID) })
            #expect(abs(pts(packet) - 9000) <= 1)
        }
    }

    @Test func decodeTimestampParticipatesInSharedOrigin() async throws {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio, .video]
        let a = audio()
        writer.audioFormat = a.format
        writer.append(a, when: time(10.1))
        let v = try video(10.25, dts: CMTime(seconds: 10, preferredTimescale: 48_000))
        writer.videoFormat = v.formatDescription
        writer.append(v)
        writer.clear()
        let result = await packets(output)
        let ap = try #require(result.first { $0.pid == TSWriter.defaultAudioPID })
        let vp = try #require(result.first { $0.pid == TSWriter.defaultVideoPID })
        #expect(abs(pts(ap) - 18_000) <= 1)
        #expect(abs(pts(vp) - 31_500) <= 1)
        #expect(vp.payload[8] == 10) // Exactly one PTS plus one DTS; no stale appended fields.
        #expect(abs(pts(vp, offset: 14) - 9000) <= 1)
        #expect(abs(pts(vp) - pts(vp, offset: 14) - 22_500) <= 1)
    }

    @Test func publicStreamExposesMuxerFailure() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio, .video])
        await stream.publish()
        await stream.append(audio(), when: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(await stream.publishingError == .muxerFailed(reason: "invalidTimestamp"))
        await connection.close()
    }

    @Test func unsupportedAudioDescriptionFailsInsteadOfWritingZeroPayload() async {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let buffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &description)!,
            packetCapacity: 1, maximumPacketSize: 4)
        buffer.byteLength = 4
        buffer.packetCount = 1
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio]
        writer.audioFormat = buffer.format
        writer.append(buffer, when: time(10))
        #expect(writer.error == .invalidPayload)
        writer.clear()
        #expect(await packets(output).isEmpty)
    }

    @Test func extremeDecodeTimestampFailsBeforePESTimestampConversion() throws {
        let writer = TSWriter()
        writer.expectedMedias = [.video]
        let v = try video(10, dts: CMTime(value: -9_000_000_000_000_000_000, timescale: 1))
        writer.videoFormat = v.formatDescription
        writer.append(v)
        #expect(writer.error == .startupTimeLimitExceeded)
    }
    @Test func stalledTransportConsumerFailsInsteadOfGrowingForever() {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio]
        let a = audio()
        writer.audioFormat = a.format
        for index in 0..<300 { writer.append(a, when: time(10 + Double(index) / 48)) }
        #expect(writer.error != nil)
        withExtendedLifetime(output) {}
    }

    @Test func oversizedPayloadAfterStartupFailsBeforeCopy() {
        let writer = TSWriter()
        let output = writer.output
        writer.expectedMedias = [.audio]
        let a = audio()
        writer.audioFormat = a.format
        writer.append(a, when: time(10))
        let oversized = AVAudioCompressedBuffer(format: a.format, packetCapacity: 1,
            maximumPacketSize: 9 * 1024 * 1024)
        oversized.byteLength = 9 * 1024 * 1024
        oversized.packetCount = 1
        writer.append(oversized, when: time(10.1))
        #expect(writer.error != nil)
        withExtendedLifetime(output) {}
    }

    @Test(arguments: [false, true])
    func tinyTransportOutputLimitsFailExplicitly(byteLimit: Bool) {
        let writer = TSWriter(outputLimits: .init(count: 1, bytesPerItem: byteLimit ? 1 : 4096))
        let output = writer.output
        writer.expectedMedias = [.audio]
        let a = audio()
        writer.audioFormat = a.format
        writer.append(a, when: time(10))
        #expect(writer.error == (byteLimit ? .outputByteLimitExceeded : .outputQueueLimitExceeded))
        withExtendedLifetime(output) {}
    }

    @Test func videoPayloadLimitStillAppliesAfterCommonOriginIsKnown() throws {
        let writer = TSWriter(maximumPayloadBytes: 32)
        let output = writer.output
        writer.expectedMedias = [.video]
        let first = try video(10)
        writer.videoFormat = first.formatDescription
        writer.append(first)
        #expect(writer.error == nil)
        writer.append(try video(10.1, payloadBytes: 64))
        #expect(writer.error == .payloadByteLimitExceeded)
        withExtendedLifetime(output) {}
    }

}

private final class PassthroughTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func append(_ data: Data) { lock.withLock { stored += data.count } }
}

private final class StartupMuxFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRTStream.MuxedPacketFrame] = []
    var rows: [SRTStream.MuxedPacketFrame] { lock.withLock { stored } }
    func record(_ frame: SRTStream.MuxedPacketFrame) { lock.withLock { stored.append(frame) } }
}

private final class TransportSendFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRTStream.TransportSendObservation] = []
    var rows: [SRTStream.TransportSendObservation] { lock.withLock { stored } }
    func record(_ frame: SRTStream.TransportSendObservation) { lock.withLock { stored.append(frame) } }
}
