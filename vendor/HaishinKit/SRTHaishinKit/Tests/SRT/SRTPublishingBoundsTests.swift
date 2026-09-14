import AVFoundation
import Foundation
import HaishinKit
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTPublishingBoundsTests {

    @Test func releasingOldConnectionDoesNotInvalidateNewSessionSocket() async throws {
        var old: SRTConnection? = SRTConnection()
        let fresh = SRTConnection()
        #expect(old != nil)
        old = nil
        #expect(try await fresh.getSocketOption(.conntimeo)?.intValue == 3000)
        await fresh.close()
    }

    @Test func idlePeerFailureIsObservedByOwnedMonitorWithoutSending() async throws {
        let status = SocketStatus()
        let socket = SRTSocket(sender: { Int32($0.count) }, statusProvider: { status.value })
        let connection = SRTConnection(socket: socket)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        status.value = .broken
        let deadline = ContinuousClock.now + .seconds(3)
        while await connection.connected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await connection.connected == false)
        #expect(await connection.publishingError == .transportWriteFailed)
        await connection.close()
    }

    @Test func connectionObservesAsynchronousSocketFailureAndClosesStream() async throws {
        let socket = SRTSocket(sender: { _ in -1 })
        let connection = SRTConnection(socket: socket)
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video])
        await stream.publish()
        #expect(await connection.connected)
        try await socket.send(Data([1]))
        let deadline = ContinuousClock.now + .seconds(2)
        while await connection.connected && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await connection.publishingError == .transportWriteFailed)
        #expect(await connection.connected == false)
        await connection.close()
        #expect(await stream.readyState == .idle)
    }

    @Test func closedConnectionRejectsStaleGenerationSend() async throws {
        let recorder = BytesRecorder()
        let socket = SRTSocket(sender: { recorder.append($0); return Int32($0.count) })
        let connection = SRTConnection(socket: socket)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        let session = try #require(await connection.publishingSession())
        await connection.close()
        await connection.send(Data([9]), generation: session)
        #expect(recorder.bytes.isEmpty)
        #expect(await connection.publishingError == nil)
    }

    @Test func closeDiscardsLateCompressedAppend() async throws {
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio])
        await stream.publish()
        await stream.close()
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let audio = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &description)!,
            packetCapacity: 1, maximumPacketSize: 4)
        await stream.append(audio, when: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(await stream.muxerError == nil)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test func finiteShorterConfiguredTimeoutsArePreserved() async throws {
        let socket = SRTSocket()
        try await socket.setSocketOption(.init(name: .conntimeo, value: 100))
        try await socket.setSocketOption(.init(name: .sndtimeo, value: 200))
        try await socket.enforceTimeouts()
        #expect(try await socket.getSocketOption(.conntimeo).intValue == 100)
        #expect(try await socket.getSocketOption(.sndtimeo).intValue == 200)
        await socket.stopRunning()
    }

    @Test func socketOversizeIsRejectedBeforeChunking() async {
        let socket = SRTSocket(outputLimits: .init(count: 1, bytesPerItem: 2), sender: { Int32($0.count) })
        await socket.startRunning()
        do {
            try await socket.send(Data([1, 2, 3]))
            Issue.record("Oversize send succeeded")
        } catch {}
        #expect(await socket.publishingError == .itemSizeExceeded(boundary: "SRT socket", bytes: 3, limit: 2))
        await socket.stopRunning()
    }

    @Test func socketWriteFailureNotifiesWithoutAnotherSend() async {
        let socket = SRTSocket(sender: { _ in -1 })
        let events = await socket.failureEvents
        await socket.startRunning()
        try? await socket.send(Data([1]))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .transportWriteFailed)
        #expect(await socket.publishingError == .transportWriteFailed)
        await socket.stopRunning()
    }

    @Test func socketChunksLazilyInByteOrder() async {
        let recorder = BytesRecorder()
        let socket = SRTSocket(sender: { recorder.append($0); return Int32($0.count) })
        await socket.startRunning()
        let input = Data((0..<4000).map { UInt8($0 % 251) })
        try? await socket.send(input)
        for _ in 0..<1000 {
            if recorder.bytes.count == input.count { break }
            await Task.yield()
        }
        await socket.stopRunning()
        #expect(recorder.bytes == input)
        #expect(recorder.sizes == [1316, 1316, 1316, 52])
    }

    @Test func socketTimeoutDefaultsAreFinite() async throws {
        let socket = SRTSocket()
        try await socket.enforceTimeouts()
        #expect(try await socket.getSocketOption(.conntimeo).intValue == 3000)
        #expect(try await socket.getSocketOption(.sndtimeo).intValue == 500)
        #expect(try await socket.getSocketOption(.rcvtimeo).intValue == 500)
        await socket.stopRunning()
    }
}

private final class BytesRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    var bytes: Data { lock.withLock { chunks.reduce(into: Data()) { $0.append($1) } } }
    var sizes: [Int] { lock.withLock { chunks.map(\.count) } }
    func append(_ bytes: Data) { lock.withLock { chunks.append(bytes) } }
}


private final class SocketStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SRTSocket.Status = .connected
    var value: SRTSocket.Status {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
