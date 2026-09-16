import AVFoundation
import Foundation
import HaishinKit
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite(.serialized) struct SRTStreamPaddingTests {
    @Test(arguments: [1_000_000, 2_000_000]) func probeReachesTargetWithoutDependingOnAnotherMediaFrameAndThenExpires(rate: Int) async throws {
        let output = StreamPaddingBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(0))
        let end = ContinuousClock.now + .seconds(2)
        while output.videoStarts < 1 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.videoStarts == 1)
        let generation = try #require(await stream.publishingGeneration)
        let started = try await stream.beginBandwidthProbe(bitRate: rate, publishingGeneration: generation)
        try await Task.sleep(for: .milliseconds(240))
        let observedAt = ProcessInfo.processInfo.systemUptime
        let active = try #require(await stream.bandwidthProbeSnapshot)
        let accountedBits = Double(active.acceptedPayloadBytes / 1316) * 1360 * 8
        print("Probe finite accounted rate: \(accountedBits / (observedAt - started.startedAt)) bps")
        print("Probe intervals: \(output.intervals)")
        #expect(accountedBits / (observedAt - started.startedAt) >= Double(rate) * 0.8)
        #expect(active.reason == nil)
        try await Task.sleep(for: .milliseconds(120))
        let expired = try #require(await stream.bandwidthProbeSnapshot)
        #expect(expired.reason == .leaseExpired)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await stream.bandwidthProbeSnapshot?.acceptedPayloadBytes == expired.acceptedPayloadBytes)
        #expect(output.videoStarts == 1)
        await stream.finish(); await connection.close()
        #expect(await stream.publishingError == nil)
    }
    @Test func concurrentCloseJoinsWakeOwnerBeforePublicationCanRestart() async throws {
        let gate = StreamProbeWakeGate(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in await gate.wait() })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation)
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        let first = Task { await stream.close(); gate.didClose() }
        end = ContinuousClock.now + .seconds(1)
        while await stream.bandwidthProbeSnapshot?.reason != .closed && ContinuousClock.now < end { await Task.yield() }
        try #require(await stream.bandwidthProbeSnapshot?.reason == .closed)
        let second = Task { await stream.close(); gate.didClose() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.closes == 0)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration == nil)
        gate.release(); await first.value; await second.value
        #expect(gate.closes == 2)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration != nil)
        await stream.close(); await connection.close()
    }
    @Test func finishStillJoinsOriginalDrainWhenCloseOverlaps() async throws {
        let wake = StreamProbeWakeGate(), peer = PaddingMediaGate(), output = StreamPaddingBytes()
        defer { wake.release(); peer.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            peer.enter(); output.append(data); return Int32(data.count)
        }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in await wake.wait() })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        var end = ContinuousClock.now + .seconds(1)
        while output.videoStarts < 1 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.videoStarts == 1)
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation)
        peer.arm(); await stream.append(try paddingVideo(1))
        end = ContinuousClock.now + .seconds(1)
        while (!wake.entered || !peer.entered) && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered && peer.entered)
        let first = Task { await stream.finish() }
        end = ContinuousClock.now + .seconds(1)
        while await stream.publishingGeneration != nil && ContinuousClock.now < end { await Task.yield() }
        try #require(await stream.publishingGeneration == nil)
        let close = Task { await stream.close() }
        end = ContinuousClock.now + .seconds(1)
        while await stream.readyState != .idle && ContinuousClock.now < end { await Task.yield() }
        try #require(await stream.readyState == .idle)
        let second = Task { await stream.finish(); wake.didClose() }
        try await Task.sleep(for: .milliseconds(10))
        wake.release(); await close.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(wake.closes == 0, "Finish must join the original blocked transport drain")
        peer.release(); await first.value; await second.value
        #expect(wake.closes == 1)
        await connection.close()
    }
    @Test func defaultDisabledAndUnreadyPublicationCannotProbe() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let disabled = SRTStream(connection: connection)
        await #expect(throws: SRTBandwidthProbeError.disabled) {
            try await disabled.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: 0)
        }
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await #expect(throws: SRTBandwidthProbeError.notPublishing) {
            try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        }
        await connection.close()
    }
    @Test func scopedProbeAddsOnlyNullsAndFinishStopsItBeforeMediaDrain() async throws {
        let output = StreamPaddingBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let started = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        }
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.renewBandwidthProbe(id: UUID(), publishingGeneration: generation)
        }
        try await Task.sleep(for: .milliseconds(55))
        _ = try await stream.renewBandwidthProbe(id: started.id, publishingGeneration: generation)
        await stream.append(try paddingVideo(1))
        let end = ContinuousClock.now + .seconds(1)
        while output.nulls == 0 && ContinuousClock.now < end { await Task.yield() }
        #expect(output.nulls == 7)
        let accepted = try #require(await stream.bandwidthProbeSnapshot)
        #expect(accepted.id == started.id && accepted.acceptedPayloadBytes == 1316)
        await stream.append(try paddingVideo(2)); await stream.finish()
        let finished = try #require(await stream.bandwidthProbeSnapshot)
        #expect(finished.reason == .finished)
        #expect(finished.acceptedPayloadBytes == accepted.acceptedPayloadBytes)
        #expect(output.videoStarts == 3)
        #expect(await stream.publishingError == nil)
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(3))
        let next = try #require(await stream.publishingGeneration)
        let reset = await stream.bandwidthProbeSnapshot
        #expect(next != generation && reset == nil)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.renewBandwidthProbe(id: started.id, publishingGeneration: generation)
        }
        let fresh = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: next)
        #expect(fresh.id != started.id && fresh.acceptedPayloadBytes == 0)
        await stream.close()
        #expect(await stream.bandwidthProbeSnapshot?.reason == .closed)
        await connection.close()
    }
    @Test func pendingMuxerAccountingIncludesQueuedDataButExcludesConsumerHeldPayload() async throws {
        let writer = TSWriter(); writer.expectedMedias = [.video]
        var iterator = writer.output.makeAsyncIterator()
        let sample = try paddingVideo(0); writer.videoFormat = sample.formatDescription; writer.append(sample)
        #expect(writer.pendingOutputCount == 2) // Program plus the PES.
        _ = await iterator.next(); writer.didDequeueOutput()
        #expect(writer.pendingOutputCount == 1)
        _ = await iterator.next(); writer.didDequeueOutput()
        #expect(writer.pendingOutputCount == 0)
        writer.clear(); #expect(writer.pendingOutputCount == 0)
    }
    @Test(arguments: [false, true]) func queuedMediaWinsAndFinishRevokesBeforeBlockedSendReturns(finish: Bool) async throws {
        let output = StreamPaddingBytes(), gate = PaddingMediaGate()
        defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            gate.enter(); output.append(data); return Int32(data.count)
        }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(0))
        var end = ContinuousClock.now + .seconds(2)
        while output.videoStarts < 1 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.videoStarts == 1)
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        gate.arm(); await stream.append(try paddingVideo(1))
        end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        try await Task.sleep(for: .milliseconds(55))
        #expect(output.nulls == 0)
        await stream.append(try paddingVideo(2)); await stream.append(try paddingVideo(3))
        var finishing: Task<Void, Never>?
        if finish {
            finishing = Task { await stream.finish() }
            end = ContinuousClock.now + .seconds(1)
            while await stream.bandwidthProbeSnapshot?.reason == nil && ContinuousClock.now < end { await Task.yield() }
            #expect(await stream.bandwidthProbeSnapshot?.reason == .finished)
        }
        gate.release()
        end = ContinuousClock.now + .seconds(2)
        while (output.videoStarts < 4 || (!finish && output.nulls == 0)) && ContinuousClock.now < end { await Task.yield() }
        if let finishing { await finishing.value } else { await stream.finish() }
        #expect(output.videoStarts == 4)
        #expect(output.nulls == (finish ? 0 : 7))
        #expect(output.mediaPrecedesPadding)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }
    @Test func configurationChangeRevokesProbe() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        try await stream.setVideoSettings(.init(bitRate: 1_000_000))
        #expect(await stream.bandwidthProbeSnapshot?.reason == .replaced)
        await stream.finish(); await connection.close()
    }
    @Test func mediaQueuedDuringSocketHopStillPrecedesPadding() async throws {
        let output = StreamPaddingBytes(), gate = PaddingStatisticsGate()
        defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: gate.read))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        var end = ContinuousClock.now + .seconds(2)
        while output.videoStarts < 1 && ContinuousClock.now < end { await Task.yield() }
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
        gate.arm(); await stream.append(try paddingVideo(1))
        end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        await stream.append(try paddingVideo(2))
        gate.release()
        end = ContinuousClock.now + .seconds(2)
        while (output.videoStarts < 3 || output.nulls == 0) && ContinuousClock.now < end { await Task.yield() }
        #expect(output.videoStarts == 3 && output.nulls == 7)
        #expect(output.mediaPrecedesPadding)
        await stream.finish(); await connection.close()
    }
    @Test func configurationDuringAdmissionRejectsSuspendedProbeStart() async throws {
        let gate = PaddingStatisticsGate(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: gate.read))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        gate.arm()
        let starting = Task { try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation) }
        let end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        try await stream.setVideoSettings(.init(bitRate: 1_000_000))
        gate.release()
        await #expect(throws: SRTBandwidthProbeError.obsolete) { try await starting.value }
        #expect(await stream.bandwidthProbeSnapshot == nil)
        await stream.finish(); await connection.close()
    }
}
private func probeStatistics(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32) -> Int32 {
    mon.msRTT = 2; return 0
}
private final class StreamPaddingBytes: @unchecked Sendable {
    private let lock = NSLock(); private var packets: [TSPacket] = []
    private var accepted: [Double] = []
    var intervals: [Double] { lock.withLock { zip(accepted, accepted.dropFirst()).map { ($1 - $0) * 1000 } } }
    func append(_ data: Data) {
        lock.withLock {
            if data.count == 1316 && data[4..<12] == Data("SBUGPRB1".utf8) { accepted.append(ProcessInfo.processInfo.systemUptime) }
            for at in stride(from: 0, to: data.count, by: 188) {
                if at + 188 <= data.count, let p = TSPacket(data: data.subdata(in: at..<at + 188)) { packets.append(p) }
            }
        }
    }
    var nulls: Int { lock.withLock { packets.filter { $0.pid == 0x1fff }.count } }
    var videoStarts: Int { lock.withLock { packets.filter { $0.pid == 256 && $0.payloadUnitStartIndicator }.count } }
    var mediaPrecedesPadding: Bool { lock.withLock {
        guard let first = packets.firstIndex(where: { $0.pid == 0x1fff }),
              let last = packets.lastIndex(where: { $0.pid == 256 && $0.payloadUnitStartIndicator }) else { return true }
        return first > last
    } }
}
private final class PaddingMediaGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var armed = false, didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func arm() { lock.withLock { armed = true } }
    func enter() {
        let block = lock.withLock { if !armed { return false }; armed = false; didEnter = true; return true }
        if block { _ = signal.wait(timeout: .now() + 5) }
    }
    func release() { signal.signal() }
}
private final class PaddingStatisticsGate: @unchecked Sendable {
    private let gate = PaddingMediaGate()
    var entered: Bool { gate.entered }
    func arm() { gate.arm() }
    func release() { gate.release() }
    func read(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32) -> Int32 {
        if clear == 0 { gate.enter() }
        mon.msRTT = 2; return 0
    }
}
// Minimal compressed transport fixture, not a pixel-decode qualification.
private func paddingVideo(_ frame: Int) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
        width: 16, height: 16, extensions: nil, formatDescriptionOut: &format) == noErr)
    let bytes: [UInt8] = [0, 0, 0, 2, 0x65, 0x7a]
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr)
    bytes.withUnsafeBytes { raw in
        #expect(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
    var size = bytes.count; var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private final class StreamProbeWakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var closeCount = 0
    var entered: Bool { lock.withLock { continuation != nil } }
    var closes: Int { lock.withLock { closeCount } }
    func didClose() { lock.withLock { closeCount += 1 } }
    func wait() async {
        await withCheckedContinuation { c in
            lock.withLock {
                if released { c.resume() } else { continuation = c }
            }
        }
    }
    func release() {
        lock.withLock { released = true; continuation?.resume(); continuation = nil }
    }
}
