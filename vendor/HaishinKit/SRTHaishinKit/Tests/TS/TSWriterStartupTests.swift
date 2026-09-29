import AVFoundation
import CoreMedia
@testable import HaishinKit
import Testing
import libsrt
@testable import SRTHaishinKit

// These tests deliberately block native calls; concurrent gates can exhaust the cooperative pool.
@Suite(.serialized) struct TSWriterStartupTests {
    @Test func videoFormatChangesKeepPayloadContinuityThroughWraparound() throws {
        var writes: [Data] = []
        let writer = TSWriter(outputSink: { writes.append($0); return true })
        writer.expectedMedias = [.video]
        var index = 0
        // Both boundaries avoid zero: 240p ends at 14, 360p spans 15, 0, 1.
        for (width, height, count) in [(426, 240, 15), (640, 360, 3), (426, 240, 2)] {
            for _ in 0..<count {
                let sample = try video(Double(index) / 30, width: Int32(width), height: Int32(height))
                writer.videoFormat = sample.formatDescription
                writer.append(sample)
                index += 1
            }
        }
        #expect(writer.error == nil)
        #expect(payloadCounters(writes, pid: TSWriter.defaultVideoPID) == (0..<20).map { UInt8($0 % 16) })
    }

    @Test func audioFormatChangesKeepPayloadContinuityThroughWraparound() {
        var writes: [Data] = []
        let writer = TSWriter(outputSink: { writes.append($0); return true })
        writer.expectedMedias = [.audio]
        var index = 0
        for (sampleRate, count) in [(48_000.0, 15), (44_100.0, 3), (48_000.0, 2)] {
            for _ in 0..<count {
                let sample = audio(sampleRate: sampleRate)
                writer.audioFormat = sample.format
                writer.append(sample, when: time(Double(index) / 30))
                index += 1
            }
        }
        #expect(writer.error == nil)
        #expect(payloadCounters(writes, pid: TSWriter.defaultAudioPID) == (0..<20).map { UInt8($0 % 16) })
    }

    @Test func clearStartsNewPublicationWithZeroAudioAndVideoCounters() throws {
        var writes: [Data] = []
        let writer = TSWriter(outputSink: { writes.append($0); return true })
        for publication in 0..<2 {
            writer.expectedMedias = [.audio, .video]
            for index in 0..<3 {
                let timestamp = Double(publication * 100) + Double(index) / 30
                let sample = audio()
                writer.audioFormat = sample.format
                writer.append(sample, when: time(timestamp))
                let frame = try video(timestamp, width: 426, height: 240)
                writer.videoFormat = frame.formatDescription
                writer.append(frame)
            }
            #expect(writer.error == nil)
            writer.finishOutput()
            #expect(payloadCounters(writes, pid: TSWriter.defaultAudioPID) == [0, 1, 2])
            #expect(payloadCounters(writes, pid: TSWriter.defaultVideoPID) == [0, 1, 2])
            writer.clear()
            writes.removeAll()
        }
    }

    // Inspect serialized TS headers, independently of the writer's packet decoder.
    private func payloadCounters(_ writes: [Data], pid: UInt16) -> [UInt8] {
        var counters: [UInt8] = []
        for data in writes {
            #expect(data.count.isMultiple(of: 188))
            for offset in stride(from: 0, to: data.count, by: 188) {
                let bytes = Array(data[offset..<(offset + 188)])
                #expect(bytes[0] == 0x47)
                let packetPID = UInt16(bytes[1] & 0x1f) << 8 | UInt16(bytes[2])
                guard packetPID == pid, bytes[3] & 0x10 != 0 else { continue }
                if bytes[3] & 0x20 != 0, bytes[4] > 0 {
                    #expect(bytes[5] & 0x80 == 0, "Format replacement keeps one continuous transport timeline")
                }
                counters.append(bytes[3] & 0x0f)
            }
        }
        return counters
    }

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
        writer.finishOutput()
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

    @Test func transportDrainsQueuedMediaWhileSynchronousVideoConversionIsBlocked() async throws {
        let conversion = PumpSynchronousGate(), firstSend = PumpSynchronousGate(), sent = PumpCounter()
        defer { conversion.release(); firstSend.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in PumpBlockedSession(gate: conversion) })
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            let count = sent.increment()
            if count == 1 { firstSend.block() }
            return Int32(data.count)
        }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        for index in 0..<3 { await stream.append(try video(Double(index) / 30)) }
        let enteredSend = await pumpWait { firstSend.entered }
        try #require(enteredSend)
        await stream.append(try pumpRawVideo())
        let enteredConversion = await pumpWait { conversion.entered }
        try #require(enteredConversion)
        firstSend.release()
        let drainedWhileBlocked = await pumpWait { sent.count >= 4 }
        let conversionStillBlocked = !conversion.released && !conversion.timedOut
        conversion.release()
        await stream.finish()
        #expect(drainedWhileBlocked && conversionStillBlocked,
                "Prequeued transport must drain without resuming the blocked stream actor")
        #expect(!firstSend.timedOut && !conversion.timedOut)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test func encodedAudioDrainsWhileNativeVideoSubmissionIsBlocked() async throws {
        let conversion = PumpSynchronousGate(), sent = PumpCounter(), observed = StartupMuxFrames()
        defer { conversion.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in PumpBlockedSession(gate: conversion) })
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            _ = sent.increment(); return Int32(data.count)
        }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            muxedPacketObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.audio]); await stream.publish()
        await stream.append(try pumpRawVideo())
        let entered = await pumpWait { conversion.entered }
        try #require(entered)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        pcm.frameLength = 4096
        if let data = pcm.floatChannelData { memset(data[0], 0, 4096 * MemoryLayout<Float>.size) }
        let audio = Task { await stream.append(pcm, when: AVAudioTime(sampleTime: 0, atRate: 48_000)) }
        let audioDrained = await pumpWait { observed.rows.contains { $0.media == .audio } && sent.count > 0 }
        let stillBlocked = !conversion.released && !conversion.timedOut
        conversion.release()
        await audio.value
        await stream.finish()
        #expect(audioDrained && stillBlocked, "PCM must encode, mux and reach transport before video conversion returns")
        #expect(!conversion.timedOut)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test(arguments: ["begin", "replace", "restart"])
    func probeAdmissionRejectsPendingVideoMutation(mode: String) async throws {
        let gate = PumpSynchronousGate()
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in PumpBlockedSession(gate: gate) })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) },
            statisticsReader: { _, mon, _, _ in mon.msRTT = 2; return 0 }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            allowsBandwidthProbes: true, probeWakeRunner: { _, _ in })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try video(0))
        let generation = try #require(await stream.publishingGeneration)
        let previous = mode == "begin" ? nil : try await stream.beginBandwidthProbe(
            bitRate: 250_000, publishingGeneration: generation, staged: true, repeatable: true)
        await stream.append(try pumpRawVideo())
        let entered = await pumpWait { gate.entered }
        try #require(entered)
        let mutation = Task { try await stream.setVideoSettings(.init(bitRate: 1_000_000)) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await stream.isVideoMutationPending) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.isVideoMutationPending)
        do {
            switch mode {
            case "replace":
                _ = try await stream.replaceBandwidthProbe(id: previous!.id,
                    publishingGeneration: generation, stage: 1, bitRate: 500_000)
            case "restart":
                _ = try await stream.restartBandwidthProbe(id: previous!.id,
                    publishingGeneration: generation, stage: 1, bitRate: 250_000)
            default:
                _ = try await stream.beginBandwidthProbe(bitRate: 250_000, publishingGeneration: generation)
            }
            Issue.record("A probe must not acquire authority while a video mutation awaits native conversion")
        } catch { #expect(error is SRTBandwidthProbeError) }
        gate.release(); try await mutation.value
        await stream.finish(); await connection.close()
        #expect(!gate.timedOut)
    }

    @Test func encodedPacingUsesTimeAfterSubmissionCommit() async throws {
        let gate = PumpSynchronousGate(), calls = PumpCounter(), sleeps = PumpCounter()
        let frames = PumpCompressedFrames()
        defer { gate.release() }
        let first = try video(0.1), second = try video(0.6)
        let codec = VideoCodec(sessionFactory: { _, _ in
            PumpEarlyOutputSession(gate: gate, calls: calls, first: first, second: second)
        })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            compressedVideoObserver: frames.record, pacesEncodedVideo: true,
            pacingSleep: { _ in _ = sleeps.increment() })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try pumpRawVideo())
        let firstObserved = await pumpWait { frames.rows.count == 1 }
        try #require(firstObserved)
        await stream.append(try pumpRawVideo(18))
        let entered = await pumpWait { gate.entered }
        try #require(entered)
        // The next frame becomes due while its native call still owns the session.
        try await Task.sleep(for: .milliseconds(650))
        #expect(frames.rows.count == 1, "Early native output must wait for submission commit")
        gate.release(); await stream.finish(); await connection.close()
        #expect(frames.rows.count == 2)
        if frames.rows.count == 2 {
            #expect(frames.rows[1].dequeuedAt - frames.rows[0].dequeuedAt < 0.5,
                    "Fixture must dequeue before the next frame's due time")
        }
        #expect(sleeps.count == 0, "An already-due frame must not be delayed again after commit")
        #expect(!gate.timedOut)
    }

    @Test func slowSubmissionKeepsOnlyBoundedNewestRawTailAndFinishJoinsIt() async throws {
        let gate = PumpSynchronousGate(), native = PumpTrackedSession()
        native.gate = gate
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try video(0))
        await stream.append(try pumpRawVideo())
        let entered = await pumpWait { gate.entered }; try #require(entered)
        for frame in 4...13 { await stream.append(try pumpRawVideo(Int64(frame))) }
        #expect(native.frames == [3])
        #expect(await stream.rawVideoFramesDropped == 8)
        let finished = PumpCounter()
        let finish = Task { await stream.finish(); _ = finished.increment() }
        // A concurrent actor call proves finish has not blocked actor access.
        _ = await stream.videoSettings
        #expect(finished.count == 0)
        gate.release(); await finish.value
        #expect(native.frames == [3, 12, 13])
        #expect(native.maximumConcurrent == 1)
        #expect(native.completed == 1 && native.invalidations == 1)
        #expect(await stream.publishingError == nil)
        #expect(!gate.timedOut)
        await connection.close()
    }

    @Test(arguments: ["settings", "invalidation", "failure", "passthrough", "finish", "close"])
    func verifiedReceiptReadsExistingConfigurationAndRejectsInvalidation(action: String) async throws {
        let native = PumpTrackedSession()
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let invalidation = PumpCodecInvalidation(codec)
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        await stream.append(try pumpRawVideo())
        let submitted = await pumpWait { native.frames.count == 1 }; try #require(submitted)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        let written = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        let writes = native.propertyWrites, reads = native.propertyReads
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let writtenSettings = try encoder.encode(written.change.settings)
        for _ in 0..<3 {
            let current = try #require(await stream.verifiedVideoBitRateReceipt)
            #expect(current.publishingGeneration == written.publishingGeneration)
            #expect(current.change.configuration == written.change.configuration)
            #expect(try encoder.encode(current.change.settings) == writtenSettings)
            #expect(current.change.acceptedAt == written.change.acceptedAt)
            #expect(current.change.lastSubmittedSourcePTS == written.change.lastSubmittedSourcePTS)
        }
        #expect(native.propertyWrites == writes && native.propertyReads == reads)
        switch action {
        case "settings": try await stream.setVideoSettings(.init(bitRate: 800_000))
        case "invalidation": invalidation.request()
        case "failure":
            native.failPropertyWrites()
            await #expect(throws: (any Swift.Error).self) {
                try await stream.setVerifiedVideoBitRateWithReceipt(800_000, publishingGeneration: generation)
            }
        case "passthrough": await stream.append(try video(0.2))
        case "finish": await stream.finish()
        default: await stream.close()
        }
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        if action == "invalidation" {
            #expect(await stream.publishingGeneration == generation,
                "An implicit encoder invalidation must revoke the receipt even while publication remains healthy")
        }
        await connection.close()
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
    }

    @Test(arguments: [false, true])
    func pendingMutationHidesEarlierVerifiedReceipt(cancel: Bool) async throws {
        let gate = PumpSynchronousGate(), native = PumpTrackedSession()
        native.gate = gate; native.gatedFrameCount = 2
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try pumpRawVideo())
        let submitted = await pumpWait { native.frames.count == 1 }; try #require(submitted)
        let old = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        await stream.append(try pumpRawVideo(4))
        let entered = await pumpWait { gate.entered }; try #require(entered)
        let change = Task { try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000, publishingGeneration: generation) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await stream.isVideoMutationPending) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.isVideoMutationPending)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        if cancel { change.cancel() }
        gate.release()
        if cancel {
            await #expect(throws: CancellationError.self) { try await change.value }
            #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration == old.change.configuration)
        } else {
            let written = try await change.value
            #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration == written.change.configuration)
            #expect(written.change.configuration != old.change.configuration)
        }
        await connection.close()
        #expect(!gate.timedOut)
    }

    @Test(arguments: [false, true])
    func bitrateMutationJoinsLastOldFrameAndRejectsOvertaking(cancel: Bool) async throws {
        let gate = PumpSynchronousGate(), native = PumpTrackedSession()
        native.gate = gate
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try video(0)); await stream.append(try pumpRawVideo())
        let entered = await pumpWait { gate.entered }; try #require(entered)
        let change = Task { try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000, publishingGeneration: generation) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await stream.isVideoMutationPending) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.isVideoMutationPending)
        await stream.append(try pumpRawVideo(4))
        #expect(native.frames == [3] && native.rates == [640_000])
        await #expect(throws: VideoBitRateUpdateError.sessionInvalidated) {
            try await stream.setVerifiedVideoBitRate(900_000, publishingGeneration: generation)
        }
        if cancel { change.cancel() }
        gate.release()
        if cancel {
            await #expect(throws: CancellationError.self) { try await change.value }
        } else {
            let receipt = try await change.value
            #expect(receipt.change.lastSubmittedSourcePTS == CMTime(value: 3, timescale: 30))
            #expect(receipt.change.configuration.bitRate == 1_000_000)
        }
        await stream.finish()
        #expect(native.frames == [3, 4])
        #expect(native.rates == [640_000, cancel ? 640_000 : 1_000_000])
        #expect(native.maximumConcurrent == 1)
        #expect(!gate.timedOut)
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test(arguments: [false, true])
    func pendingNativeMutationRejectsInterveningPassthrough(replace: Bool) async throws {
        let gate = PumpSynchronousGate(), native = PumpTrackedSession()
        native.gate = gate
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try video(0)); await stream.append(try pumpRawVideo())
        let entered = await pumpWait { gate.entered }; try #require(entered)
        let change = Task {
            if replace {
                _ = try await stream.replaceVideoSettings(.init(videoSize: CGSize(width: 32, height: 32),
                    allowFrameReordering: false), publishingGeneration: generation)
            } else {
                _ = try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000, publishingGeneration: generation)
            }
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await stream.isVideoMutationPending) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.isVideoMutationPending)
        await stream.append(try video(0.2))
        gate.release()
        if replace {
            await #expect(throws: SRTStream.VideoReplacementError.notEncoding) { try await change.value }
        } else {
            await #expect(throws: VideoBitRateUpdateError.notEncoding) { try await change.value }
        }
        #expect(await stream.videoSettings.bitRate == 640_000)
        await stream.finish(); await connection.close()
        #expect(!gate.timedOut)
    }

    @Test func closeRetainsBlockedSessionAndRejectsMutationUntilWorkerReturns() async throws {
        let gate = PumpSynchronousGate(), native = PumpTrackedSession(), returned = PumpCounter()
        native.gate = gate
        defer { gate.release() }
        let codec = VideoCodec(sessionFactory: { _, _ in native })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec))
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try pumpRawVideo())
        let entered = await pumpWait { gate.entered }; try #require(entered)
        let close = Task { await stream.close(); _ = returned.increment() }
        let deadline = ContinuousClock.now + .seconds(1)
        while await stream.readyState != .idle, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.readyState == .idle)
        #expect(native.invalidations == 0 && returned.count == 0)
        await #expect(throws: SRTStream.VideoReplacementError.busy) {
            try await stream.setVideoSettings(.init(bitRate: 900_000))
        }
        await stream.publish()
        #expect(await stream.publishingGeneration == nil)
        gate.release(); await close.value
        #expect(native.invalidations == 1 && returned.count == 1)
        await stream.publish()
        #expect(await stream.publishingGeneration != nil)
        await stream.append(try video(10)); await stream.finish()
        #expect(await stream.publishingError == nil)
        #expect(!gate.timedOut)
        await connection.close()
    }

    @Test(arguments: [false, true])
    func republishWaitsForCancelledTransportBeforeReusingConnection(closeWhileWaiting: Bool) async throws {
        let firstSend = PumpSynchronousGate(), returned = PumpCounter()
        defer { firstSend.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { data in
            firstSend.block(); return Int32(data.count)
        }))
        let stream = SRTStream(connection: connection)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try video(0))
        let entered = await pumpWait { firstSend.entered }
        try #require(entered)
        await stream.close()
        await stream.setExpectedMedias([.video])
        let publishing = Task { await stream.publish(); _ = returned.increment() }
        try await Task.sleep(for: .milliseconds(50))
        let returnedBeforeOldSend = returned.count
        if closeWhileWaiting { await stream.close() }
        firstSend.release()
        await publishing.value
        #expect(returnedBeforeOldSend == 0, "New publication must join the retired transport")
        #expect(await stream.publishingGeneration == nil, "Cancelled entered socket send closes its connection")
        #expect(!firstSend.timedOut)
        await connection.close()
    }

    @Test(arguments: [false, true])
    func retiredWorkerCannotOverlapOrResurrectHealthyConnection(closeWhileWaiting: Bool) async throws {
        let returnedSend = PumpSynchronousGate(), observations = PumpCounter(), returnedPublish = PumpCounter()
        defer { returnedSend.release() }
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, transportSendObserver: { event in
            // Deliberately gate the test worker after a successful socket return;
            // production observers must never block. This keeps the connection healthy.
            if event.phase == .returned, observations.increment() == 1 { returnedSend.block() }
        })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        await stream.setExpectedMedias([.video]); await stream.publish()
        await stream.append(try video(0))
        let entered = await pumpWait { returnedSend.entered }
        try #require(entered)
        await stream.close()
        await stream.setExpectedMedias([.video])
        let publishing = Task { await stream.publish(); _ = returnedPublish.increment() }
        try await Task.sleep(for: .milliseconds(50))
        let returnedBeforeRetirement = returnedPublish.count
        if closeWhileWaiting { await stream.close() }
        returnedSend.release()
        await publishing.value
        #expect(returnedBeforeRetirement == 0)
        #expect(await connection.connected)
        #expect((await stream.publishingGeneration != nil) == !closeWhileWaiting)
        #expect(!returnedSend.timedOut)
        await stream.close(); await connection.close()
    }

    @Test func interleavingHoldsLeadingAudioUntilVideoAndDrainsEveryPacket() throws {
        let writer = TSWriter(outputSink: { _ in true })
        writer.expectedMedias = [.audio, .video]
        var rows: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { rows.append($0) }
        let a = audio(), v = try video(10)
        writer.audioFormat = a.format; writer.videoFormat = v.formatDescription
        writer.append(a, when: time(10)); writer.append(v)
        writer.append(a, when: time(10.02)); writer.append(a, when: time(10.04))
        #expect(rows.count == 2, "Encoded audio must not run ahead of available video")
        writer.append(try video(10.033))
        #expect(rows.map { $0.media.rawValue } == ["audio", "video", "audio", "video"])
        writer.append(a, when: time(10.06))
        writer.append(try video(10.067))
        writer.finishOutput()
        #expect(writer.error == nil)
        #expect(rows.count == 7)
        let times = rows.map { $0.transportDTS ?? $0.transportPTS }
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func interleavingOrdersByDecodeTimeAndPreservesPresentationTime() throws {
        let writer = TSWriter(outputSink: { _ in true })
        writer.expectedMedias = [.audio, .video]
        var rows: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { rows.append($0) }
        let a = audio(), v = try video(10.1, dts: CMTime(seconds: 10, preferredTimescale: 48000))
        writer.audioFormat = a.format; writer.videoFormat = v.formatDescription
        writer.append(a, when: time(10)); writer.append(v)
        writer.append(try video(10.2, dts: CMTime(seconds: 10.033, preferredTimescale: 48000)))
        #expect(rows.count == 2, "Leading video must also wait for audio")
        writer.append(a, when: time(10.04))
        #expect(rows.last?.sourcePTS == CMTime(seconds: 10.2, preferredTimescale: 48000))
        writer.finishOutput()
        #expect(rows.count == 4 && writer.error == nil)
    }

    @Test(arguments: ["packets", "bytes", "span"])
    func interleavingRejectsStalledTrackAtFiniteBounds(_ bound: String) throws {
        let limits = TSWriter.InterleaveLimits(packetCount: bound == "packets" ? 3 : 256,
            byteCount: bound == "bytes" ? 256 : 8 * 1024 * 1024,
            mediaSpan: bound == "span" ? 0.1 : 2)
        let writer = TSWriter(interleaveLimits: limits, outputSink: { _ in true })
        writer.expectedMedias = [.audio, .video]
        let a = audio(), v = try video(10)
        writer.audioFormat = a.format; writer.videoFormat = v.formatDescription
        writer.append(a, when: time(10)); writer.append(v)
        for i in 1...50 { writer.append(a, when: time(10 + Double(i) / 50)) }
        let expected: SRTStream.MuxerError = bound == "packets" ? .interleavePacketLimitExceeded
            : bound == "bytes" ? .interleaveByteLimitExceeded : .interleaveTimeLimitExceeded
        #expect(writer.error == expected)
        writer.finishOutput()
        #expect(writer.error == expected)
        writer.clear()
        #expect(writer.error == nil)
    }

    @Test func interleavingRejectsReversedDecodeTimeAndClearDiscardsOldTail() throws {
        let writer = TSWriter(outputSink: { _ in true })
        writer.expectedMedias = [.audio, .video]
        let a = audio(), v = try video(10)
        writer.audioFormat = a.format; writer.videoFormat = v.formatDescription
        writer.append(a, when: time(10)); writer.append(v)
        writer.append(a, when: time(10.1)); writer.append(a, when: time(10.05))
        #expect(writer.error == .invalidTimestamp)
        writer.clear()
        writer.expectedMedias = [.audio]
        writer.audioFormat = a.format
        var rows: [TSWriter.MuxedPacketFrame] = []
        writer.muxedPacketObserver = { rows.append($0) }
        writer.append(a, when: time(0)); writer.finishOutput()
        #expect(writer.error == nil && rows.count == 1)
        #expect(rows.first?.sourcePTS == time(0).makeTime())
    }

    private func audio(_ marker: UInt8 = 42, sampleRate: Double = 48_000) -> AVAudioCompressedBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
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

    private func video(_ seconds: Double, dts: CMTime = .invalid, payloadBytes: Int = 6,
                       width: Int32 = 16, height: Int32 = 16) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: width, height: height, extensions: nil, formatDescriptionOut: &format) == noErr)
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
        writer.finishOutput()
        writer.clear()
        let result = await packets(output)
        let audioPackets = result.filter { $0.pid == TSWriter.defaultAudioPID && $0.payloadUnitStartIndicator }
        let videoPackets = result.filter { $0.pid == TSWriter.defaultVideoPID && $0.payloadUnitStartIndicator }
        #expect(audioPackets.count == 5 && videoPackets.count == 1)
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
        writer.finishOutput()
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
        writer.finishOutput()
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

private final class PumpCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
private final class PumpSynchronousGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isEntered = false, isReleased = false, expired = false
    var entered: Bool { condition.withLock { isEntered } }
    var released: Bool { condition.withLock { isReleased } }
    var timedOut: Bool { condition.withLock { expired } }
    func block() {
        condition.lock(); defer { condition.unlock() }
        isEntered = true
        let deadline = Date().addingTimeInterval(5)
        while !isReleased {
            if !condition.wait(until: deadline) { expired = true; return }
        }
    }
    func release() { condition.withLock { isReleased = true; condition.broadcast() } }
}
private final class PumpBlockedSession: VTSessionConvertible {
    let gate: PumpSynchronousGate
    init(gate: PumpSynchronousGate) { self.gate = gate }
    func setOption(_ option: VTSessionOption) -> OSStatus { noErr }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?,
                 encoderCompletionObserver: VideoEncoderCompletionObserver?) throws { gate.block() }
    func completeFrames() -> OSStatus { noErr }
    func invalidate() {}
}
private func pumpWait(_ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while !predicate() && ContinuousClock.now < deadline { await Task.yield() }
    return predicate()
}
private func pumpRawVideo(_ frame: Int64 = 3) throws -> CMSampleBuffer {
    var image: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil, &image) == kCVReturnSuccess)
    let buffer = try #require(image)
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: frame, timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private final class PumpCompressedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SRTStream.CompressedVideoFrame] = []
    var rows: [SRTStream.CompressedVideoFrame] { lock.withLock { stored } }
    func record(_ frame: SRTStream.CompressedVideoFrame) { lock.withLock { stored.append(frame) } }
}
private final class PumpEarlyOutputSession: VTSessionConvertible {
    let gate: PumpSynchronousGate, calls: PumpCounter
    let first: CMSampleBuffer, second: CMSampleBuffer
    init(gate: PumpSynchronousGate, calls: PumpCounter, first: CMSampleBuffer, second: CMSampleBuffer) {
        self.gate = gate; self.calls = calls; self.first = first; self.second = second
    }
    func setOption(_ option: VTSessionOption) -> OSStatus { noErr }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?,
                 encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        let count = calls.increment()
        let output = count == 1 ? first : second
        encoderCompletionObserver?(sampleBuffer.presentationTimeStamp, output.presentationTimeStamp)
        continuation?.yield(output, byteCount: output.totalSampleSize)
        if count == 2 { gate.block() }
    }
    func completeFrames() -> OSStatus { noErr }
    func invalidate() {}
}

private final class PumpTrackedSession: VTSessionConvertible, @unchecked Sendable {
    var gate: PumpSynchronousGate?
    var gatedFrameCount = 1
    private let lock = NSLock()
    private var sourceFrames: [Int64] = [], sourceRates: [Int] = []
    private var properties: [String: CFTypeRef] = [:]
    private var active = 0, maximum = 0, drains = 0, retired = 0
    private var writes = 0, reads = 0
    private var propertyWriteFails = false
    var propertyWrites: Int { lock.withLock { writes } }
    var propertyReads: Int { lock.withLock { reads } }
    func failPropertyWrites() { lock.withLock { propertyWriteFails = true } }
    var frames: [Int64] { lock.withLock { sourceFrames } }
    var rates: [Int] { lock.withLock { sourceRates } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    var completed: Int { lock.withLock { drains } }
    var invalidations: Int { lock.withLock { retired } }
    func setOption(_ option: VTSessionOption) -> OSStatus {
        lock.withLock {
            #expect(active == 0); writes += 1
            guard !propertyWriteFails else { return -77 }
            properties[option.key.CFString as String] = option.value
            return noErr
        }
    }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) {
        lock.withLock { #expect(active == 0); reads += 1; return (noErr, properties[key.CFString as String]) }
    }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
        for option in options { _ = setOption(option) }; return noErr
    }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?,
                 encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        let first = lock.withLock {
            active += 1; maximum = max(maximum, active)
            sourceFrames.append(CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 30, method: .default).value)
            sourceRates.append((properties[VTSessionOptionKey.averageBitRate.CFString as String] as? NSNumber)?.intValue ?? 640_000)
            return sourceFrames.count == gatedFrameCount
        }
        if first { gate?.block() }
        lock.withLock { active -= 1 }
    }
    func completeFrames() -> OSStatus { lock.withLock { #expect(active == 0); drains += 1 }; return noErr }
    func invalidate() { lock.withLock { #expect(active == 0); retired += 1 } }
}

/// Only calls the codec's thread-safe external invalidation entry point.
private final class PumpCodecInvalidation: @unchecked Sendable {
    private weak var codec: VideoCodec?
    init(_ codec: VideoCodec) { self.codec = codec }
    func request() { codec?.requestSessionInvalidation() }
}
