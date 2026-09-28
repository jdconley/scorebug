import AVFoundation
import Foundation
import HaishinKit
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite(.serialized) struct SRTStreamPaddingTests {
    /// Opt-in wall-clock diagnosis through the real native pump and socket path.
    /// The socket accepts every write: this measures sender scheduling, not network capacity.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCOREBUG_PROBE_TIMING_DIAGNOSTIC"] == "1"),
          arguments: [9_192_000, 12_000_000, 36_192_000, 48_000_000])
    func uhdSenderSchedulingDiagnostic(rate: Int) async throws {
        let output = StreamPaddingBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true, probeBudget: .uhd)
        await connection.addStream(stream)
        do {
            try await connection.connect(URL(string: "srt://127.0.0.1:1"))
            await stream.setExpectedMedias([.video]); await stream.publish()
            await stream.append(try paddingVideo(0))
            let ready = ContinuousClock.now + .seconds(2)
            while output.videoStarts < 1 && ContinuousClock.now < ready { await Task.yield() }
            try #require(output.videoStarts == 1)
            let generation = try #require(await stream.publishingGeneration)
            let started = try await stream.beginBandwidthProbe(bitRate: rate, publishingGeneration: generation,
                staged: true, repeatable: true)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                let renewed = try await stream.renewBandwidthProbe(id: started.id, publishingGeneration: generation)
                try #require(renewed.reason == nil)
            }
            let active = try #require(await stream.bandwidthProbeSnapshot)
            let elapsed = ProcessInfo.processInfo.systemUptime - started.startedAt
            let actual = Double(active.acceptedPayloadBytes / 1316) * 1360 * 8 / elapsed
            print("UHD_SENDER_DIAGNOSTIC requested=\(rate) accepted=\(actual) ratio=\(actual / Double(rate)) seconds=\(elapsed)")
            #expect(active.reason == nil)
            #expect(active.acceptedPayloadBytes > 0)
            _ = try await stream.retireBandwidthProbe(id: started.id, publishingGeneration: generation)
            await stream.finish(); await connection.close()
        } catch {
            await stream.finish(); await connection.close()
            throw error
        }
    }
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
            probeWakeRunner: { probe, accounting in
                let scheduler = Task {
                    await SRTProbeWakeSchedule.run(probe: probe, wake: { accounting.wake() })
                }
                let deadline = ContinuousClock.now + .seconds(1)
                while !Task.isCancelled && ContinuousClock.now < deadline {
                    let sample = probe.snapshot(now: { ProcessInfo.processInfo.systemUptime })
                    if sample.acceptedPayloadBytes > 0 || sample.reason != nil { break }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                scheduler.cancel(); await scheduler.value
                await gate.wait()
            })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        _ = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation)
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        // Padding acceptance follows the single transport consumer's completed
        // media sends. Closing an entered media send intentionally kills its
        // connection; this test isolates joining the probe wake owner instead.
        let accepted = await stream.bandwidthProbeSnapshot?.acceptedPayloadBytes ?? 0
        try #require(accepted > 0)
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
        let connected = await connection.connected
        let connectionError = await connection.publishingError
        #expect(connected, "Republish requires a surviving connection; error=\(String(describing: connectionError))")
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration != nil)
        await stream.close(); await connection.close()
    }
    @Test func closeDuringEnteredMediaSendTerminatesConnectionBeforeRepublish() async throws {
        let media = PaddingMediaGate(); defer { media.release() }
        let socket = SRTSocket(sender: { data in
            media.enter(); return Int32(data.count)
        }, statisticsReader: probeStatistics)
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        media.arm()
        await stream.append(try paddingVideo(0))
        var end = ContinuousClock.now + .seconds(2)
        while !media.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(media.entered)
        // close cancels the transport task while its socket send is entered.
        // Releasing the native call exposes that cancellation at the next check.
        await stream.close()
        media.release()
        end = ContinuousClock.now + .seconds(2)
        while await connection.publishingError == nil && ContinuousClock.now < end { await Task.yield() }
        let error = await connection.publishingError
        #expect(await socket.publishingError == .outputTerminated(boundary: "SRT socket cancelled send"))
        // The connection's send catch and failure observer race to latch the
        // terminal reason; both must close it, while the socket reason is exact.
        #expect(error != nil)
        end = ContinuousClock.now + .seconds(2)
        while await connection.connected && ContinuousClock.now < end { await Task.yield() }
        #expect(await connection.connected == false)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration == nil)
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
private func probeStatistics(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32, _ instantaneous: Int32) -> Int32 {
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
    func read(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32, _ instantaneous: Int32) -> Int32 {
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

extension SRTStreamPaddingTests {
    @Test func uhdBudgetSurvivesReplacementAndJoinedRestart() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true, probeBudget: .uhd)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        do {
            let generation = try #require(await stream.publishingGeneration)
            await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
            }
            let first = try await stream.beginBandwidthProbe(bitRate: 36_192_000, publishingGeneration: generation, staged: true, repeatable: true)
            #expect(first.budget == .uhd && first.campaign == 1)
            let next = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 48_000_000)
            #expect(next.budget == .uhd && next.stage == 2)
            #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
            try await stream.cancelBandwidthProbe(id: next.id, publishingGeneration: generation)
            let restarted = try await stream.restartBandwidthProbe(id: next.id, publishingGeneration: generation, stage: 2, bitRate: 36_192_000)
            #expect(restarted.budget == .uhd && restarted.campaign == 2 && restarted.stage == 1)
            try await stream.cancelBandwidthProbe(id: restarted.id, publishingGeneration: generation)
        } catch {
            await stream.finish(); await connection.close(); throw error
        }
        await stream.finish(); await connection.close()
    }

    @Test func stagedBeginAndReplacementAcceptHighRateButKeepVersionedCeilings() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        do {
            let generation = try #require(await stream.publishingGeneration)
            await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try await stream.beginBandwidthProbe(bitRate: 2_000_001, publishingGeneration: generation)
            }
            await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try await stream.beginBandwidthProbe(bitRate: 12_000_001, publishingGeneration: generation, staged: true)
            }
            let first = try await stream.beginBandwidthProbe(bitRate: 12_000_000, publishingGeneration: generation, staged: true)
            #expect(first.bitRate == 12_000_000 && first.stage == 1)
            await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 12_000_001)
            }
            #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == true)
            let next = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 12_000_000)
            #expect(next.bitRate == 12_000_000 && next.stage == 2)
            #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
            try await stream.cancelBandwidthProbe(id: next.id, publishingGeneration: generation)
        } catch {
            await stream.finish(); await connection.close(); throw error
        }
        await stream.finish(); await connection.close()
    }

    @Test func stagedReplacementPreservesAccountingAndRejectsRetiredIdentity() async throws {
        let output = StagedPaddingBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        let authority = try #require(first.authority)
        #expect(first.stage == 1 && first.campaignStartedAt == first.startedAt)
        var end = ContinuousClock.now + .seconds(1)
        while output.count(stage: 1) < 2 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.count(stage: 1) >= 2)
        let second = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        #expect(second.stage == 2 && second.id != first.id)
        #expect(second.campaignStartedAt == first.campaignStartedAt)
        #expect(second.acceptedPayloadBytes == 0)
        #expect(second.totalAcceptedPayloadBytes == UInt64(output.count(stage: 1) * 1316))
        #expect(!authority.permits(id: first.id, generation: generation, stage: 1))
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.replaceBandwidthProbe(id: second.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        end = ContinuousClock.now + .seconds(1)
        while output.count(stage: 2) < 2 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.count(stage: 2) >= 2)
        try await stream.cancelBandwidthProbe(id: second.id, publishingGeneration: generation)
        let final = try #require(await stream.bandwidthProbeSnapshot)
        #expect(final.totalAcceptedPayloadBytes == UInt64(output.total * 1316))
        #expect(final.acceptedPayloadBytes == UInt64(output.count(stage: 2) * 1316))
        #expect(output.stagesAreOrderedAndSequencesRestart)
        await stream.finish(); await connection.close()
        #expect(await stream.publishingError == nil)
    }

    @Test func replacementRevokesBeforeJoiningWakeAndCannotOverlapAnotherAdmission() async throws {
        let gate = StreamProbeWakeGate(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { probe, _ in
                if probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }).stage == 1 { await gate.wait() }
            })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        #expect(first.reason == nil, "Installation captures the initial receipt before exposing the probe")
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        let replacement = Task { try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000) }
        end = ContinuousClock.now + .seconds(1)
        while await stream.bandwidthProbeSnapshot?.reason != .replaced && ContinuousClock.now < end { await Task.yield() }
        #expect(await stream.bandwidthProbeSnapshot?.reason == .replaced)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        gate.release()
        let second = try await replacement.value
        #expect(second.stage == 2 && second.reason == nil)
        await stream.finish(); await connection.close()
    }

    @Test(arguments: ["cancel", "caller", "configuration", "finish", "close"])
    func interruptedReplacementCannotAdmitAfterWakeJoin(action: String) async throws {
        let gate = StreamProbeWakeGate(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in await gate.wait() })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        #expect(first.reason == nil, "Installation captures the initial receipt before exposing the probe")
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        let replacing = Task { try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000) }
        end = ContinuousClock.now + .seconds(1)
        while await stream.bandwidthProbeSnapshot?.reason != .replaced && ContinuousClock.now < end { await Task.yield() }
        try #require(await stream.bandwidthProbeSnapshot?.reason == .replaced)
        var stopping: Task<Void, Never>?
        switch action {
        case "cancel": try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
        case "caller": replacing.cancel()
        case "configuration": try await stream.setVideoSettings(.init(bitRate: 1_000_000))
        case "finish": stopping = Task { await stream.finish() }
        default: stopping = Task { await stream.close() }
        }
        if stopping != nil {
            end = ContinuousClock.now + .seconds(1)
            while await stream.publishingGeneration != nil && ContinuousClock.now < end { await Task.yield() }
            #expect(await stream.publishingGeneration == nil)
        }
        gate.release()
        let result = await replacing.result
        switch result {
        case .success: Issue.record("Interrupted replacement admitted a new stage")
        case .failure(let error):
            if action == "caller" { #expect(error is CancellationError) }
            else { #expect(error as? SRTBandwidthProbeError == .obsolete) }
        }
        await stopping?.value
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        await stream.close(); await connection.close()
    }

    @Test func configurationChangeDuringReplacementStatisticsRejectsNewStage() async throws {
        let gate = PaddingStatisticsGate(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: gate.read))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        gate.arm()
        let replacing = Task { try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000) }
        let end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        try await stream.setAudioSettings(.init(bitRate: 64_000))
        gate.release()
        await #expect(throws: SRTBandwidthProbeError.obsolete) { try await replacing.value }
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        await stream.finish(); await connection.close()
    }

    @Test func legacyProbeCannotEnterStagedCampaignAndInvalidRequestDoesNotRetireIt() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let legacy = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.replaceBandwidthProbe(id: legacy.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        #expect(legacy.authority?.permits(id: legacy.id, generation: generation, stage: nil) == true)
        await stream.close(); await connection.close()
    }

    @Test(arguments: [false, true]) func closedStreamCannotRepublishUntilPendingProbeAdmissionReturns(replacement: Bool) async throws {
        let gate = PaddingStatisticsGate(), output = StreamPaddingBytes(); defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: gate.read))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let mediaDeadline = ContinuousClock.now + .seconds(1)
        while output.videoStarts < 1 && ContinuousClock.now < mediaDeadline { await Task.yield() }
        try #require(output.videoStarts == 1)
        let generation = try #require(await stream.publishingGeneration)
        let first: SRTBandwidthProbeSnapshot?
        if replacement { first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true) }
        else { first = nil }
        gate.arm()
        let pending = Task {
            if let first {
                return try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
            }
            return try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        }
        let end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        await stream.close()
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration == nil, "Pending old probe admission must prevent republish")
        gate.release()
        await #expect(throws: SRTBandwidthProbeError.obsolete) { try await pending.value }
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration != nil)
        #expect(await stream.bandwidthProbeSnapshot == nil)
        await stream.close(); await connection.close()
    }

    @Test func failedReplacementCanRetryCurrentRetiredStageWithoutResettingCampaign() async throws {
        let statistics = StagedProbeStatistics()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: statistics.read))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        statistics.failNext()
        await #expect(throws: SRTBandwidthProbeError.unavailableStatistics) {
            try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        let next = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        #expect(next.stage == 2 && next.id != first.id)
        #expect(next.campaignStartedAt == first.campaignStartedAt)
        #expect(next.totalAcceptedPayloadBytes == first.totalAcceptedPayloadBytes)
        await stream.finish(); await connection.close()
    }

    @Test func replacementJoinsNativeAcceptanceBeforeCopyingCumulativeBytes() async throws {
        let gate = PaddingMediaGate(), progress = StreamProbeWakeGate(), output = StagedPaddingBytes()
        defer { gate.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            if data.count == 1316 && data[4..<12] == Data("SBUGPRB2".utf8) { gate.enter() }
            output.append(data); return Int32(data.count)
        }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        gate.arm()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        #expect(first.reason == nil, "Installation captures the initial receipt before exposing the probe")
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        let replacing = Task {
            progress.didClose()
            let next = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
            progress.didClose()
            return next
        }
        end = ContinuousClock.now + .seconds(1)
        while progress.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(progress.closes == 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(progress.closes == 1, "Replacement must join an in-flight native send")
        gate.release()
        let second = try await replacing.value
        #expect(second.stage == 2 && second.acceptedPayloadBytes == 0)
        #expect(second.totalAcceptedPayloadBytes == 1316)
        #expect(output.count(stage: 1) == 1)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        await stream.finish(); await connection.close()
    }

    @Test func stageLimitDoesNotResetWithinPublication() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true,
            probeWakeRunner: { _, _ in })
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        var current = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        for stage in UInt32(1)..<32 {
            let next = try await stream.replaceBandwidthProbe(id: current.id, publishingGeneration: generation, stage: stage, bitRate: 500_000)
            #expect(next.stage == stage + 1)
            #expect(current.authority?.permits(id: current.id, generation: generation, stage: stage) == false)
            current = next
        }
        await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try await stream.replaceBandwidthProbe(id: current.id, publishingGeneration: generation, stage: 32, bitRate: 500_000)
        }
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        }
        #expect(await stream.bandwidthProbeSnapshot?.stage == 32)
        await stream.finish(); await connection.close()
    }
}

private final class StagedPaddingBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(stage: UInt32, sequence: UInt64)] = []
    func append(_ data: Data) {
        guard data.count == 1316, [Data("SBUGPRB2".utf8), Data("SBUGPRB3".utf8)].contains(data[4..<12]) else { return }
        let stage = data[49..<53].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let sequence = data[36..<44].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        lock.withLock { messages.append((stage, sequence)) }
    }
    func count(stage: UInt32) -> Int { lock.withLock { messages.filter { $0.stage == stage }.count } }
    var total: Int { lock.withLock { messages.count } }
    var stagesAreOrderedAndSequencesRestart: Bool { lock.withLock {
        var stage: UInt32 = 0, next: UInt64 = 0
        for message in messages {
            if message.stage != stage {
                guard message.stage > stage else { return false }
                stage = message.stage; next = 0
            }
            guard message.sequence == next else { return false }
            next += 1
        }
        return true
    } }
}

private final class StagedProbeStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var nextFails = false
    func failNext() { lock.withLock { nextFails = true } }
    func read(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32, _ instantaneous: Int32) -> Int32 {
        let invalid = lock.withLock {
            if clear == 0 && nextFails { nextFails = false; return true }
            return false
        }
        mon.msRTT = invalid ? .nan : 2
        return 0
    }
}

extension SRTStreamPaddingTests {
    @Test func repeatableRequiresStagedAndPreservesCampaignUntilRestart() async throws {
        let (stream, connection, generation) = try await restartFixture()
        await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, repeatable: true)
        }
        #expect(await stream.bandwidthProbeSnapshot == nil)
        var current = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        #expect(current.campaign == 1)
        let renewed = try await stream.renewBandwidthProbe(id: current.id, publishingGeneration: generation)
        #expect(renewed.campaign == 1 && renewed.id == current.id)
        for expectedCampaign: UInt32 in [1, 2, 3] {
            let previous = current
            current = try await stream.replaceBandwidthProbe(id: current.id,
                publishingGeneration: generation, stage: 1, bitRate: 500_000)
            #expect(current.campaign == expectedCampaign && current.stage == 2)
            #expect(current.campaignStartedAt == previous.campaignStartedAt)
            #expect(current.totalAcceptedPayloadBytes == previous.totalAcceptedPayloadBytes)
            #expect(current.id != previous.id)
            try await stream.cancelBandwidthProbe(id: current.id, publishingGeneration: generation)
            current = try await stream.restartBandwidthProbe(id: current.id,
                publishingGeneration: generation, stage: 2, bitRate: 1_000_000)
            #expect(current.campaign == expectedCampaign + 1 && current.stage == 1)
            #expect(current.totalAcceptedPayloadBytes == 0 && current.campaignStartedAt == current.startedAt)
        }
        await stream.finish(); await connection.close()
    }

    @Test func terminalLegacyV2CannotRestartIntoAnotherStageOne() async throws {
        let (stream, connection, generation) = try await restartFixture()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true)
        try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
        let retired = try #require(await stream.bandwidthProbeSnapshot)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        }
        #expect(await stream.bandwidthProbeSnapshot == retired)
        await stream.finish(); await connection.close()
    }

    @Test func restartBeginsFreshCampaignAndAccountingWithoutRepublishing() async throws {
        let output = StagedPaddingBytes()
        let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: probeStatistics))
        let stream = SRTStream(connection: connection, allowsBandwidthProbes: true)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
        let generation = try #require(await stream.publishingGeneration)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true, repeatable: true)
        let end = ContinuousClock.now + .seconds(1)
        while output.total < 2 && ContinuousClock.now < end { await Task.yield() }
        try #require(output.total >= 2)
        try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
        let retired = try #require(await stream.bandwidthProbeSnapshot)
        try #require((retired.totalAcceptedPayloadBytes ?? 0) > 0)
        let next = try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 12_000_000)
        #expect(first.campaign == 1 && next.campaign == 2)
        #expect(next.id != first.id && next.stage == 1 && next.reason == nil)
        #expect(next.publishingGeneration == generation && next.bitRate == 12_000_000)
        #expect(next.startedAt > first.startedAt && next.campaignStartedAt == next.startedAt)
        #expect(next.acceptedPayloadBytes == 0 && next.totalAcceptedPayloadBytes == 0 && next.lastAcceptedAt == nil)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        #expect(next.authority?.permits(id: next.id, generation: generation, stage: 1) == true)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1)
        }
        await stream.finish(); await connection.close()
        #expect(await stream.publishingError == nil)
    }

    @Test(arguments: [false, true]) func restartRejectsActiveAndLegacyProbe(staged: Bool) async throws {
        let (stream, connection, generation) = try await restartFixture()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: staged, repeatable: staged)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        }
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: staged ? 1 : nil) == true)
        if !staged {
            try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
            await #expect(throws: SRTBandwidthProbeError.obsolete) {
                try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
            }
        }
        await stream.finish(); await connection.close()
    }

    @Test func restartValidatesIdentityGenerationStageRateAndEnabledState() async throws {
        let (stream, connection, generation) = try await restartFixture()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true, repeatable: true)
        try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
        for rate in [0, -1, 12_000_001, Int.max] {
            await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
                try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: rate)
            }
        }
        for stage in [UInt32(0), 2, 33, UInt32.max] {
            await #expect(throws: SRTBandwidthProbeError.obsolete) {
                try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: stage, bitRate: 1)
            }
        }
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.restartBandwidthProbe(id: UUID(), publishingGeneration: generation, stage: 1, bitRate: 1)
        }
        await #expect(throws: SRTBandwidthProbeError.notPublishing) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation + 1, stage: 1, bitRate: 1)
        }
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        let disabled = SRTStream(connection: connection)
        await #expect(throws: SRTBandwidthProbeError.disabled) {
            try await disabled.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1)
        }
        await stream.finish()
        await #expect(throws: SRTBandwidthProbeError.notPublishing) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1)
        }
        await connection.close()
    }

    @Test(arguments: ["none", "cancel", "caller", "configuration", "finish", "close"])
    func restartJoinsWakeOwnerAndRejectsConcurrentAdmissionOrInterruption(action: String) async throws {
        let gate = StreamProbeWakeGate(); defer { gate.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { probe, _ in
            probe.cancel(.leaseExpired)
            await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.didClose() }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        let pending = Task { try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000) }
        end = ContinuousClock.now + .seconds(1)
        while gate.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.closes == 1)
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        }
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        }
        let stopping = try await interruptRestart(action, stream: stream, first: first, pending: pending)
        gate.release()
        if action == "none" {
            let next = try await pending.value
            #expect(next.id != first.id && next.stage == 1 && next.totalAcceptedPayloadBytes == 0)
        } else {
            await expectRestartInterruption(pending, action: action)
            #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        }
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        await stopping?.value
        await stream.close(); await connection.close()
    }

    @Test(arguments: ["cancel", "caller", "configuration", "finish", "close"])
    func restartRevalidatesAfterStatisticsSuspension(action: String) async throws {
        let gate = PaddingStatisticsGate(); defer { gate.release() }
        let (stream, connection, generation) = try await restartFixture(statisticsReader: gate.read)
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true, repeatable: true)
        try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: generation)
        gate.arm()
        let pending = Task { try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000) }
        let end = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(gate.entered)
        await #expect(throws: SRTBandwidthProbeError.alreadyStarted) {
            try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        }
        let stopping = try await interruptRestart(action, stream: stream, first: first, pending: pending)
        if action == "close" {
            await stopping?.value
            await stream.setExpectedMedias([.video]); await stream.publish()
            #expect(await stream.publishingGeneration == nil)
        }
        gate.release()
        await expectRestartInterruption(pending, action: action)
        await stopping?.value
        #expect(await stream.bandwidthProbeSnapshot?.id == first.id)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        await stream.close(); await connection.close()
    }

    @Test func restartRetriesFailedStatisticsUsingRetiredIdentity() async throws {
        let statistics = StagedProbeStatistics()
        let (stream, connection, generation) = try await restartFixture(statisticsReader: statistics.read)
        var last = try await stream.beginBandwidthProbe(bitRate: 1_000_000, publishingGeneration: generation, staged: true, repeatable: true)
        for stage in UInt32(1)..<32 {
            last = try await stream.replaceBandwidthProbe(id: last.id, publishingGeneration: generation, stage: stage, bitRate: 1)
        }
        try await stream.cancelBandwidthProbe(id: last.id, publishingGeneration: generation)
        statistics.failNext()
        await #expect(throws: SRTBandwidthProbeError.unavailableStatistics) {
            try await stream.restartBandwidthProbe(id: last.id, publishingGeneration: generation, stage: 32, bitRate: 1)
        }
        #expect(await stream.bandwidthProbeSnapshot?.id == last.id)
        #expect(last.authority?.permits(id: last.id, generation: generation, stage: 32) == false)
        let next = try await stream.restartBandwidthProbe(id: last.id, publishingGeneration: generation, stage: 32, bitRate: 1)
        #expect(last.campaign == 1 && next.campaign == 2)
        #expect(next.id != last.id && next.stage == 1 && next.reason == nil)
        #expect(next.campaignStartedAt == next.startedAt && next.startedAt > last.startedAt)
        #expect(next.totalAcceptedPayloadBytes == 0)
        await stream.finish(); await connection.close()
    }
}

private func restartFixture(
    statisticsReader: @escaping @Sendable (SRTSOCKET, inout CBytePerfMon, Int32, Int32) -> Int32 = probeStatistics,
    probeWakeRunner: @escaping @Sendable (SRTBandwidthProbe, TransportOutputAccounting) async -> Void = { _, _ in }
) async throws -> (SRTStream, SRTConnection, UInt64) {
    let output = StreamPaddingBytes()
    let connection = SRTConnection(socket: SRTSocket(sender: { output.append($0); return Int32($0.count) }, statisticsReader: statisticsReader))
    let stream = SRTStream(connection: connection, outgoing: OutgoingStream(), allowsBandwidthProbes: true, probeWakeRunner: probeWakeRunner)
    await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
    await stream.setExpectedMedias([.video]); await stream.publish(); await stream.append(try paddingVideo(0))
    let end = ContinuousClock.now + .seconds(1)
    while output.videoStarts < 1 && ContinuousClock.now < end { await Task.yield() }
    try #require(output.videoStarts == 1)
    return (stream, connection, try #require(await stream.publishingGeneration))
}

private func interruptRestart(_ action: String, stream: SRTStream, first: SRTBandwidthProbeSnapshot,
                              pending: Task<SRTBandwidthProbeSnapshot, Error>) async throws -> Task<Void, Never>? {
    var stopping: Task<Void, Never>?
    switch action {
    case "cancel": try await stream.cancelBandwidthProbe(id: first.id, publishingGeneration: first.publishingGeneration)
    case "caller": pending.cancel()
    case "configuration": try await stream.setVideoSettings(.init(bitRate: 1_000_000))
    case "finish": stopping = Task { await stream.finish() }
    case "close": stopping = Task { await stream.close() }
    default: break
    }
    if stopping != nil {
        let end = ContinuousClock.now + .seconds(1)
        while await stream.publishingGeneration != nil && ContinuousClock.now < end { await Task.yield() }
        #expect(await stream.publishingGeneration == nil)
    }
    return stopping
}

private func expectRestartInterruption(_ pending: Task<SRTBandwidthProbeSnapshot, Error>, action: String) async {
    switch await pending.result {
    case .success: Issue.record("Interrupted restart admitted a fresh campaign")
    case .failure(let error):
        if action == "caller" { #expect(error is CancellationError) }
        else { #expect(error as? SRTBandwidthProbeError == .obsolete) }
    }
}

extension SRTStreamPaddingTests {
    @Test func recoveryPolicyIsExplicitAndInheritedAcrossReplacementAndRestart() async throws {
        let (stream, connection, generation) = try await restartFixture(statisticsReader: { _, mon, _, _ in
            mon.msRTT = 65; mon.msSndBuf = 67; mon.msSndTsbPdDelay = 400
            mon.byteSentTotal = 10_000; mon.byteRetransTotal = 100; return 0
        })
        await #expect(throws: SRTBandwidthProbeError.invalidConfiguration) {
            try await stream.beginBandwidthProbe(bitRate: 500_000, publishingGeneration: generation, policy: .recoveryBudget)
        }
        #expect(await stream.bandwidthProbeSnapshot == nil)
        let first = try await stream.beginBandwidthProbe(bitRate: 500_000, publishingGeneration: generation,
            staged: true, repeatable: true, policy: .recoveryBudget)
        #expect(first.policy == .recoveryBudget)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1, policy: .recoveryBudget) == true)
        let renewed = try await stream.renewBandwidthProbe(id: first.id, publishingGeneration: generation)
        #expect(renewed.policy == .recoveryBudget)
        let replacement = try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 1_000_000)
        #expect(replacement.policy == .recoveryBudget && replacement.stage == 2)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1, policy: .recoveryBudget) == false)
        try await stream.cancelBandwidthProbe(id: replacement.id, publishingGeneration: generation)
        let restarted = try await stream.restartBandwidthProbe(id: replacement.id, publishingGeneration: generation, stage: 2, bitRate: 500_000)
        #expect(restarted.policy == .recoveryBudget && restarted.campaign == 2)
        #expect(restarted.authority?.permits(id: restarted.id, generation: generation, stage: 1, policy: .recoveryBudget) == true)
        await stream.finish(); await connection.close()
        #expect(restarted.authority?.permits(id: restarted.id, generation: generation, stage: 1, policy: .recoveryBudget) == false)
    }
}

extension SRTStreamPaddingTests {
    @Test(arguments: [false, true])
    func exactRetirementRevokesImmediatelyAndJoinsCancellationIgnoringWake(cancelWaiter: Bool) async throws {
        let wake = StreamProbeWakeGate(), completed = StreamProbeWakeGate()
        defer { wake.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { _, _ in
            await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let retirement = Task {
            let receipt = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
            completed.didClose()
            return receipt
        }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        if cancelWaiter { retirement.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed.closes == 0, "Retirement must remain joined to the held wake")
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        #expect(await stream.publishingGeneration == generation, "Probe retirement must leave media publishing")
        wake.release()
        let receipt = try await retirement.value
        #expect(receipt.id == first.id && receipt.reason == .cancelled)
        #expect(completed.closes == 1)
        await stream.finish(); await connection.close()
    }
}

extension SRTStreamPaddingTests {
    @Test(arguments: [false, true])
    func retirementDuplicatesDoNotPoisonCrossingStageOrCampaignAllocation(restart: Bool) async throws {
        let wake = StreamProbeWakeGate(), statistics = PaddingStatisticsGate(), completed = StreamProbeWakeGate()
        defer { wake.release(); statistics.release() }
        let (stream, connection, generation) = try await restartFixture(statisticsReader: statistics.read,
            probeWakeRunner: { _, _ in
                await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
            })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let retiring = Task { try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation) }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        let duplicate = Task {
            let receipt = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
            completed.didClose()
            return receipt
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed.closes == 0)
        statistics.arm()
        let replacing = Task {
            if restart {
                return try await stream.restartBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
            }
            return try await stream.replaceBandwidthProbe(id: first.id, publishingGeneration: generation, stage: 1, bitRate: 500_000)
        }
        wake.release()
        let retired = try await retiring.value, duplicateReceipt = try await duplicate.value
        #expect(retired == duplicateReceipt && retired.reason == .cancelled)
        end = ContinuousClock.now + .seconds(1)
        while !statistics.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(statistics.entered)
        // Even after the old join completes, a duplicate must not bump revision
        // and invalidate the replacement suspended in native statistics.
        let completedDuplicate = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        #expect(completedDuplicate == retired)
        statistics.release()
        let next = try await replacing.value
        #expect(next.id != first.id && next.reason == nil)
        #expect(next.stage == (restart ? 1 : 2) && next.campaign == (restart ? 2 : 1))
        #expect(await stream.bandwidthProbeSnapshot?.id == next.id)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        }
        #expect(next.authority?.permits(id: next.id, generation: generation, stage: next.stage) == true)
        await stream.finish(); await connection.close()
    }

    @Test func retirementRejectsForeignIdentityAndGenerationBeforeRevocation() async throws {
        let (stream, connection, generation) = try await restartFixture()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: UUID(), publishingGeneration: generation)
        }
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation + 1)
        }
        #expect(await stream.bandwidthProbeSnapshot == first)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == true)
        let retired = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        #expect(retired.reason == .cancelled)
        await stream.finish(); await connection.close()
    }

    @Test(arguments: [SRTBandwidthProbeSnapshot.Reason.leaseExpired, .transportPressure, .replaced])
    func retirementPreservesExistingTerminalReason(reason: SRTBandwidthProbeSnapshot.Reason) async throws {
        let wake = StreamProbeWakeGate(); defer { wake.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { probe, _ in
            probe.cancel(reason)
            await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let retiring = Task { try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation) }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        #expect(await stream.bandwidthProbeSnapshot?.reason == reason)
        wake.release()
        #expect(try await retiring.value.reason == reason)
        await stream.finish(); await connection.close()
    }

    @Test func retirementAndCloseJoinOldWakeWithoutMutatingNextPublication() async throws {
        let wake = StreamProbeWakeGate(), completed = StreamProbeWakeGate()
        defer { wake.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { _, _ in
            await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let retiring = Task { try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation) }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        let closing = Task { await stream.close(); completed.didClose() }
        end = ContinuousClock.now + .seconds(1)
        while await stream.publishingGeneration != nil && ContinuousClock.now < end { await Task.yield() }
        #expect(await stream.publishingGeneration == nil)
        let duplicateDuringClose = Task { try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed.closes == 0)
        await stream.setExpectedMedias([.video]); await stream.publish()
        #expect(await stream.publishingGeneration == nil)
        wake.release()
        await closing.value
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(1))
        let nextGeneration = try #require(await stream.publishingGeneration)
        #expect(nextGeneration != generation)
        let next = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: nextGeneration, staged: true, repeatable: true)
        let retired = try await retiring.value, duplicate = try await duplicateDuringClose.value
        #expect(retired == duplicate && retired.id == first.id && retired.reason == .cancelled)
        #expect(await stream.bandwidthProbeSnapshot?.id == next.id)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        }
        #expect(next.authority?.permits(id: next.id, generation: nextGeneration, stage: 1) == true)
        await stream.finish(); await connection.close()
    }

    @Test func retirementRevocationRejectsLateNativeSendFromCancellationIgnoringWake() async throws {
        let wake = StreamProbeWakeGate(), sent = StreamProbeWakeGate()
        defer { wake.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { probe, _ in
            await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
            let at = ProcessInfo.processInfo.systemUptime
            var native = CBytePerfMon(); native.msRTT = 2
            let statistics = SRTPerformanceData(mon: native, sampledAt: at)
            do {
                let accepted = try probe.offer(statistics: statistics, now: { at }) { _ in
                    sent.didClose(); return true
                }
                #expect(!accepted)
            } catch { Issue.record(error) }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let retiring = Task { try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation) }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        wake.release()
        let retired = try await retiring.value
        #expect(sent.closes == 0 && retired.acceptedPayloadBytes == 0 && retired.reason == .cancelled)
        await stream.finish(); await connection.close()
    }
}

extension SRTStreamPaddingTests {
    @Test(arguments: [false, true])
    func closeFirstRetirementJoinsCapturedWakeEvenWhenWaiterCancels(cancelWaiter: Bool) async throws {
        let wake = StreamProbeWakeGate(), completed = StreamProbeWakeGate()
        defer { wake.release() }
        let (stream, connection, generation) = try await restartFixture(probeWakeRunner: { _, _ in
            await withTaskCancellationHandler { await wake.wait() } onCancel: { wake.didClose() }
        })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        let closing = Task { await stream.close() }
        end = ContinuousClock.now + .seconds(1)
        while wake.closes == 0 && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.closes == 1)
        #expect(await stream.publishingGeneration == nil)
        #expect(await stream.bandwidthProbeSnapshot?.reason == .closed)
        let retiring = Task { () -> Result<SRTBandwidthProbeSnapshot, Error> in
            do {
                let receipt = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
                completed.didClose(); return .success(receipt)
            } catch {
                completed.didClose(); return .failure(error)
            }
        }
        if cancelWaiter { retiring.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed.closes == 0, "Retained closed probe must join close's captured wake")
        wake.release(); await closing.value
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try paddingVideo(1))
        let nextGeneration = try #require(await stream.publishingGeneration)
        let next = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: nextGeneration, staged: true, repeatable: true)
        switch await retiring.value {
        case .success(let receipt):
            #expect(receipt.id == first.id && receipt.publishingGeneration == generation && receipt.reason == .closed)
        case .failure(let error): Issue.record("Exact closed owner failed retirement: \(error)")
        }
        #expect(await stream.bandwidthProbeSnapshot?.id == next.id)
        #expect(next.authority?.permits(id: next.id, generation: nextGeneration, stage: 1) == true)
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        }
        await stream.finish(); await connection.close()
    }

    @Test func completedCloseRetainsExactJoinableProbeWithoutAcceptingForeignOwners() async throws {
        let (stream, connection, generation) = try await restartFixture()
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        await stream.close()
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: UUID(), publishingGeneration: generation)
        }
        await #expect(throws: SRTBandwidthProbeError.obsolete) {
            try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation + 1)
        }
        let receipt = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
        #expect(receipt.id == first.id && receipt.reason == .closed)
        #expect(await stream.bandwidthProbeSnapshot == receipt)
        await connection.close()
    }
}

extension SRTStreamPaddingTests {
    @Test(arguments: [false, true])
    func exactRetirementDoesNotRequireHealthyPublishingGeneration(unhealthy: Bool) async throws {
        let wake = StreamProbeWakeGate(), statistics = PaddingStatisticsGate(), completed = StreamProbeWakeGate()
        defer { wake.release(); statistics.release() }
        let (stream, connection, generation) = try await restartFixture(statisticsReader: statistics.read,
            probeWakeRunner: { _, _ in await wake.wait() })
        let first = try await stream.beginBandwidthProbe(bitRate: 1_000_000,
            publishingGeneration: generation, staged: true, repeatable: true)
        var end = ContinuousClock.now + .seconds(1)
        while !wake.entered && ContinuousClock.now < end { await Task.yield() }
        try #require(wake.entered)
        var finishing: Task<Void, Never>?
        var sampling: Task<SRTPerformanceData?, Never>?
        if unhealthy {
            // Hold the connection actor so asynchronous error shutdown cannot
            // close the stream before retirement sees the unhealthy current owner.
            statistics.arm()
            sampling = Task { await connection.samplePerformanceData() }
            end = ContinuousClock.now + .seconds(1)
            while !statistics.entered && ContinuousClock.now < end { await Task.yield() }
            try #require(statistics.entered)
            let source = try paddingVideo(1)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: .indefinite, decodeTimeStamp: .invalid)
            var invalid: CMSampleBuffer?
            try #require(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: source, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &invalid) == noErr)
            await stream.append(try #require(invalid))
            #expect(await stream.publishingError != nil)
            #expect(await stream.readyState == .publishing)
        } else {
            finishing = Task { await stream.finish() }
            end = ContinuousClock.now + .seconds(1)
            while await stream.bandwidthProbeSnapshot?.reason != .finished && ContinuousClock.now < end { await Task.yield() }
            try #require(await stream.bandwidthProbeSnapshot?.reason == .finished)
        }
        #expect(await stream.publishingGeneration == nil)
        let retiring = Task { () -> Result<SRTBandwidthProbeSnapshot, Error> in
            do {
                let receipt = try await stream.retireBandwidthProbe(id: first.id, publishingGeneration: generation)
                completed.didClose(); return .success(receipt)
            } catch {
                completed.didClose(); return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed.closes == 0)
        #expect(first.authority?.permits(id: first.id, generation: generation, stage: 1) == false)
        wake.release(); statistics.release()
        switch await retiring.value {
        case .success(let receipt):
            #expect(receipt.id == first.id && receipt.reason == (unhealthy ? .cancelled : .finished))
        case .failure(let error): Issue.record("Exact unhealthy/finishing owner failed retirement: \(error)")
        }
        _ = await sampling?.value
        await finishing?.value
        await stream.close(); await connection.close()
    }
}
