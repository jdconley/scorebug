import AVFoundation
import Foundation
import HaishinKit
import Testing
@testable import SRTHaishinKit

@Suite(.serialized) struct CompressedAudioFrameTests {
    @Test(arguments: [1, 8184])
    func snapshotCopiesOnlyActualBytesAndCannotChangeWithPooledBufferReuse(bytes: Int) {
        let buffer = audio(bytes: bytes)
        let when = time(10)
        let frame = SRTStream.CompressedAudioFrame(buffer: buffer, when: when, generation: 7, wasEncoded: true, observedAt: 12)
        #expect(frame.valid && frame.byteCount == bytes)
        #expect(frame.sourcePTS == when.makeTime() && frame.publishingGeneration == 7 && frame.wasEncoded)
        #expect(frame.hostTime == when.hostTime)
        #expect(frame.observedAt == 12 && frame.sampleRate == 48_000 && frame.channelCount == 2)
        #expect(frame.framesPerPacket == 1024 && frame.audioObjectType == 2)
        buffer.data.initializeMemory(as: UInt8.self, repeating: 99, count: bytes)
        buffer.byteLength = 0
        #expect(frame.payload == Data(repeating: 42, count: bytes))
    }

    @Test(arguments: ["empty", "oversized", "packetCount", "packetOffset", "packetSize", "packetFrames", "profile", "codec", "fractionalRate", "frames", "channels", "hostTime", "generation", "observedNaN", "observedNegative"])
    func invalidSnapshotsNeverCopyPayload(fault: String) {
        let buffer = audio(bytes: fault == "empty" ? 0 : fault == "oversized" ? 8185 : 4,
            sampleRate: fault == "fractionalRate" ? 48000.5 : 48000,
            codec: fault == "codec" ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC,
            profile: fault == "profile" ? 5 : 2, frames: fault == "frames" ? 2048 : 1024,
            channels: fault == "channels" ? 7 : 2)
        if fault == "packetCount" { buffer.packetCount = 2 }
        if fault == "packetOffset" { buffer.packetDescriptions?.pointee.mStartOffset = 1 }
        if fault == "packetSize" { buffer.packetDescriptions?.pointee.mDataByteSize = 3 }
        if fault == "packetFrames" { buffer.packetDescriptions?.pointee.mVariableFramesInPacket = 512 }
        let when = fault == "hostTime" ? AVAudioTime(sampleTime: 480000, atRate: 48000) : time(10)
        let frame = SRTStream.CompressedAudioFrame(buffer: buffer, when: when,
            generation: fault == "generation" ? 0 : 1, wasEncoded: false,
            observedAt: fault == "observedNaN" ? .nan : fault == "observedNegative" ? -1 : 12)
        #expect(!frame.valid && frame.payload.isEmpty && frame.byteCount == 0)
    }

    @Test func passthroughObservesOnlyAcceptedMuxInputsWithFreshGenerationAndStopsAfterClose() async throws {
        let observed = AudioObservations()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, compressedAudioObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        do {
            await stream.append(audio(), when: time(9))
            #expect(observed.frames.isEmpty)
            await stream.setExpectedMedias([.audio]); await stream.publish()
            let firstGeneration = try #require(await stream.publishingGeneration)
            await stream.append(audio(), when: time(10))
            #expect(observed.frames.count == 1)
            #expect(observed.frames.first?.valid == true && observed.frames.first?.wasEncoded == false)
            #expect(observed.frames.first?.publishingGeneration == firstGeneration)
            await stream.finish()
            await stream.append(audio(), when: time(11))
            #expect(observed.frames.count == 1)
            await stream.setExpectedMedias([.audio]); await stream.publish()
            let secondGeneration = try #require(await stream.publishingGeneration)
            #expect(secondGeneration != firstGeneration)
            await stream.append(audio(), when: time(12))
            #expect(observed.frames.last?.publishingGeneration == secondGeneration)
            await stream.finish()
            #expect(observed.frames.count == 2)
            await connection.close()
        } catch { await stream.close(); await connection.close(); throw error }
    }

    @Test func muxRejectionSuppressesObserverAndLaterInputs() async throws {
        let observed = AudioObservations()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), compressedAudioObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio, .video]); await stream.publish()
        await stream.append(audio(), when: time(10))
        #expect(observed.frames.count == 1)
        await stream.append(audio(), when: time(12.1))
        #expect(observed.frames.count == 1)
        #expect(await stream.publishingError != nil)
        await stream.append(audio(), when: time(12.2))
        #expect(observed.frames.count == 1)
        await stream.close(); await connection.close()
    }

    @Test func nativePCMOutputIsCopiedThroughFinalDrain() async throws {
        let observed = AudioObservations()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, compressedAudioObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        do {
            await stream.setExpectedMedias([.audio]); await stream.publish()
            let generation = try #require(await stream.publishingGeneration)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            pcm.frameLength = 4096
            for channel in 0..<2 { memset(pcm.floatChannelData![channel], 0, 4096 * MemoryLayout<Float>.size) }
            await stream.append(pcm, when: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10), sampleTime: 480000, atRate: 48000))
            await stream.finish()
            let frames = observed.frames
            #expect(!frames.isEmpty)
            #expect(frames.allSatisfy { $0.valid && $0.wasEncoded && $0.publishingGeneration == generation && $0.byteCount > 0 })
            #expect(frames.allSatisfy { $0.sampleRate == 48000 && $0.channelCount == 2 && $0.framesPerPacket == 1024 && $0.audioObjectType == 2 })
            #expect(await stream.publishingError == nil)
            await stream.append(pcm, when: time(11))
            #expect(observed.frames.count == frames.count)
            await connection.close()
        } catch { await stream.close(); await connection.close(); throw error }
    }

    private func audio(bytes: Int = 4, sampleRate: Double = 48000,
                       codec: AudioFormatID = kAudioFormatMPEG4AAC, profile: UInt32 = 2,
                       frames: UInt32 = 1024, channels: UInt32 = 2) -> AVAudioCompressedBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: codec, mFormatFlags: profile,
            mBytesPerPacket: 0, mFramesPerPacket: frames, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        // Multichannel AVAudioFormat requires an explicit layout, even for a
        // deliberately unsupported AAC channel configuration under test.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        let format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 2, maximumPacketSize: max(bytes, 1))
        buffer.byteLength = UInt32(bytes); buffer.packetCount = 1
        buffer.data.initializeMemory(as: UInt8.self, repeating: 42, count: bytes)
        buffer.packetDescriptions?.pointee = .init(mStartOffset: 0, mVariableFramesInPacket: frames, mDataByteSize: UInt32(bytes))
        return buffer
    }
    private func time(_ seconds: Double) -> AVAudioTime { .init(hostTime: AVAudioTime.hostTime(forSeconds: seconds)) }
}

private final class AudioObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRTStream.CompressedAudioFrame] = []
    func record(_ frame: SRTStream.CompressedAudioFrame) { lock.withLock { stored.append(frame) } }
    var frames: [SRTStream.CompressedAudioFrame] { lock.withLock { stored } }
}
