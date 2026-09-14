import AVFoundation
import Testing
@testable import HaishinKit

@Suite struct AudioCodecPublishingTests {
    private func pcm() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 1024) }
        return buffer
    }

    @Test func converterCreationFailureLatchesAndFinishesWithoutAnotherAppend() async {
        let codec = AudioCodec(makeConverter: { _, _ in nil })
        let output = codec.outputStream
        codec.startRunning()
        codec.append(pcm(), when: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(codec.failure.error == .codecFailed(status: -50))
        var count = 0
        for await _ in output { count += 1 }
        #expect(count == 0)
        codec.stopRunning()
    }

    @Test func compressedAudioOutputFailsAtTinyCapacity() {
        let codec = AudioCodec()
        codec.outputLimits = .init(count: 1, bytesPerItem: 64 * 1024)
        let output = codec.outputStream
        codec.startRunning()
        for index in 0..<10 {
            codec.append(pcm(), when: AVAudioTime(sampleTime: Int64(index * 1024), atRate: 48_000))
        }
        #expect(codec.failure.error == .queueCapacityExceeded(boundary: "audio codec"))
        codec.stopRunning()
        withExtendedLifetime(output) {}
    }
}
