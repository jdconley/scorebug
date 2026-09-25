import AVFoundation
import Foundation
@testable import HaishinKit
import Testing
@testable import SRTHaishinKit

@Suite(.serialized) struct SRTVideoReplacementTests {
    @Test(arguments: [false, true]) func receiptRequiresActualNewOutputAndFinishPreservesBothFormats(paces: Bool) async throws {
        let observed = ReplacementFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, compressedVideoObserver: observed.record, pacesEncodedVideo: paces)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let readyDeadline = ContinuousClock.now + .seconds(2)
        while observed.frames.isEmpty && ContinuousClock.now < readyDeadline { await Task.yield() }
        #expect(observed.frames.count == 1)
        _ = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        #expect(await stream.verifiedVideoBitRateReceipt != nil)
        let change = Task {
            try await stream.replaceVideoSettings(.init(videoSize: CGSize(width: 32, height: 32),
                allowFrameReordering: false), publishingGeneration: generation)
        }
        let stagedDeadline = ContinuousClock.now + .seconds(1)
        while await stream.videoSettings.videoSize.width != 32, ContinuousClock.now < stagedDeadline { await Task.yield() }
        #expect(await stream.videoSettings.videoSize.width == 32)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        // Commit by itself cannot produce a receipt: no new frame exists yet.
        #expect(observed.frames.count == 1)
        let firstNewFrame = paces ? 15 : 1
        for frame in firstNewFrame..<(firstNewFrame + 4) {
            await stream.append(try replacementVideo(frame))
            try await Task.sleep(for: .milliseconds(5))
        }
        let receipt = try await change.value
        #expect(receipt.publishingGeneration == generation)
        #expect(receipt.encoderSessionID != receipt.previousEncoderSessionID)
        #expect(receipt.lastOldSourcePTS == .zero)
        #expect(receipt.firstNewSourcePTS == CMTime(value: Int64(firstNewFrame), timescale: 30))
        #expect(receipt.width == 32 && receipt.height == 32)
        #expect(receipt.rawVideoFramesDropped == 0)
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        let verified = try await stream.setVerifiedVideoBitRateWithReceipt(800_000, publishingGeneration: generation)
        #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration == verified.change.configuration)
        #expect(verified.change.configuration.encoderSessionID == receipt.encoderSessionID)
        await stream.finish()
        #expect(await stream.publishingError == nil)
        #expect(observed.frames.map(\.width) == [64, 32, 32, 32, 32])
        let expectedPTS = ([0] + Array(firstNewFrame..<(firstNewFrame + 4))).map { CMTime(value: Int64($0), timescale: 30) }
        #expect(observed.frames.map(\.sourcePTS) == expectedPTS)
        if paces {
            let anchor = try #require(observed.frames.first).dequeuedAt
            for (frame, at) in zip(observed.frames, observed.observedTimes) {
                #expect(at + 0.001 >= anchor + frame.sourcePTS.seconds,
                    "Replacement must retain the original source-cadence anchor")
            }
        }
        await connection.close()
    }
    @Test(arguments: ["none", "write", "settings", "close", "finish"])
    func guardedReplacementContinuationIsSingleUse(action: String) async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed)
        defer { gate.open() }
        let baseline = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, expecting: .init(baseline.change)) }
        try await gate.waitForEntry(); gate.open()
        let deadline = ContinuousClock.now + .seconds(2)
        while await stream.videoSettings.videoSize.width != 32, ContinuousClock.now < deadline { await Task.yield() }
        await stream.append(try replacementVideo(1))
        let receipt = try await change.value
        // Wrong public values must not consume the retained private continuation.
        for field in ["generation", "encoder", "previous", "old", "first", "flags", "epoch", "width", "height", "dropped"] {
            let pts = receipt.firstNewSourcePTS
            let first = field == "flags" ? CMTime(value: pts.value, timescale: pts.timescale, flags: [pts.flags, .hasBeenRounded], epoch: pts.epoch)
                : field == "epoch" ? CMTime(value: pts.value, timescale: pts.timescale, flags: pts.flags, epoch: pts.epoch + 1)
                : field == "first" ? CMTime(value: pts.value * 2, timescale: pts.timescale * 2, flags: pts.flags, epoch: pts.epoch) : pts
            let altered = SRTStream.VideoReplacementReceipt(publishingGeneration: field == "generation" ? generation + 1 : generation,
                encoderSessionID: field == "encoder" ? UUID() : receipt.encoderSessionID,
                previousEncoderSessionID: field == "previous" ? UUID() : receipt.previousEncoderSessionID,
                lastOldSourcePTS: field == "old" ? .invalid : receipt.lastOldSourcePTS, firstNewSourcePTS: first,
                width: field == "width" ? 64 : receipt.width, height: field == "height" ? 64 : receipt.height,
                rawVideoFramesDropped: field == "dropped" ? receipt.rawVideoFramesDropped + 1 : receipt.rawVideoFramesDropped)
            await #expect(throws: VideoMutationAdmissionError.stale) { try await guardedFollowup(stream, rate: 800_000, receipt: altered) }
        }
        switch action {
        case "write": _ = try await stream.setVerifiedVideoBitRateWithReceipt(800_000, publishingGeneration: generation)
        case "settings": try await stream.setVideoSettings(stream.videoSettings)
        case "close": await stream.close()
        case "finish": await stream.finish()
        default:
            await stream.append(try replacementVideo(2))
            let later = ContinuousClock.now + .seconds(2)
            while observed.frames.count < 3 && ContinuousClock.now < later { await Task.yield() }
            let accepted = try await guardedFollowup(stream, rate: 800_000, receipt: receipt)
            #expect(accepted.change.configuration.encoderSessionID == receipt.encoderSessionID)
        }
        let current = await stream.verifiedVideoBitRateReceipt
        await #expect(throws: VideoMutationAdmissionError.stale) { try await guardedFollowup(stream, rate: 900_000, receipt: receipt) }
        #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration.id == current?.change.configuration.id)
        #expect(await stream.publishingError == nil)
        await stream.finish(); await connection.close()
    }

    @Test(arguments: [false, true])
    func guardedRechecksAfterHeldSubmissionWithoutWritesOrDrains(profile: Bool) async throws {
        let gate = ReplacementGate(), counts = AdmissionCounts(), observed = ReplacementFrames()
        let codec = VideoCodec(sessionFactory: { mode, codec in
            AdmissionSession(try mode.makeSession(codec), gate: gate, counts: counts)
        })
        let invalidation = ReplacementInvalidation(codec)
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec), compressedVideoObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let ready = ContinuousClock.now + .seconds(2)
        while observed.frames.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(!observed.frames.isEmpty)
        let baseline = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        await stream.append(try replacementVideo(1)); try await gate.waitForEntry()
        defer { gate.open() }
        let writes = counts.writes, drains = counts.drains
        let mutation = Task {
            if profile {
                _ = try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, expecting: .init(baseline.change))
            } else {
                _ = try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000,
                    expecting: .verified(publishingGeneration: generation, configuration: .init(baseline.change)))
            }
        }
        let reserved = ContinuousClock.now + .seconds(1)
        while await !stream.isVideoMutationPending && ContinuousClock.now < reserved { await Task.yield() }
        try #require(await stream.isVideoMutationPending)
        invalidation.request(); gate.open()
        await #expect(throws: VideoMutationAdmissionError.stale) { try await mutation.value }
        #expect(counts.writes == writes && counts.drains == drains)
        #expect(await !stream.isVideoMutationPending)
        #expect(await stream.publishingGeneration == generation)
        #expect(await stream.publishingError == nil)
        await stream.append(try replacementVideo(2))
        let rebuilt = ContinuousClock.now + .seconds(2)
        while observed.frames.last?.sourcePTS != CMTime(value: 2, timescale: 30), ContinuousClock.now < rebuilt { await Task.yield() }
        let fresh = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        _ = try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000,
            expecting: .verified(publishingGeneration: generation, configuration: .init(fresh.change)))
        await stream.finish(); await connection.close()
    }

    @Test(arguments: [false, true], [false, true])
    func guardedOldAdmissionCannotMutateOrRetireRepublishedStream(profile: Bool, cancelled: Bool) async throws {
        let gate = ReplacementGate(), counts = AdmissionCounts(), observed = ReplacementFrames(), joined = AdmissionJoinGate()
        let codec = VideoCodec(sessionFactory: { mode, codec in
            AdmissionSession(try mode.makeSession(codec), gate: gate, counts: counts)
        })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            compressedVideoObserver: observed.record, videoMutationSubmissionJoined: { await joined.pause() })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        // Missing audio holds transport startup, isolating the admission/encoder lifecycle.
        await stream.setExpectedMedias([.audio, .video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let ready = ContinuousClock.now + .seconds(2)
        while observed.frames.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        let baseline = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        await stream.append(try replacementVideo(1)); try await gate.waitForEntry()
        defer { gate.open() }
        let mutation = Task {
            if profile {
                _ = try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, expecting: .init(baseline.change))
            } else {
                _ = try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000,
                    expecting: .verified(publishingGeneration: generation, configuration: .init(baseline.change)))
            }
        }
        let reserved = ContinuousClock.now + .seconds(1)
        while await !stream.isVideoMutationPending && ContinuousClock.now < reserved { await Task.yield() }
        try #require(await stream.isVideoMutationPending)
        // A competing matching caller also has made no encoder mutation.
        await #expect(throws: VideoMutationAdmissionError.stale) {
            try await stream.setVerifiedVideoBitRateWithReceipt(1_200_000,
                expecting: .verified(publishingGeneration: generation, configuration: .init(baseline.change)))
        }
        await #expect(throws: VideoMutationAdmissionError.stale) {
            try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, expecting: .init(baseline.change))
        }
        gate.open(); try await joined.waitForEntry()
        await stream.close()
        await stream.setExpectedMedias([.audio, .video]); await stream.publish()
        let freshGeneration = try #require(await stream.publishingGeneration)
        #expect(freshGeneration != generation)
        let frames = observed.frames.count
        await stream.append(try replacementVideo(0))
        let readyAgain = ContinuousClock.now + .seconds(2)
        while observed.frames.count == frames && ContinuousClock.now < readyAgain { await Task.yield() }
        let fresh = try await stream.setVerifiedVideoBitRateWithReceipt(800_000, publishingGeneration: freshGeneration)
        let writes = counts.writes, drains = counts.drains
        if cancelled { mutation.cancel() }
        await joined.release()
        if cancelled { await #expect(throws: CancellationError.self) { try await mutation.value } }
        else { await #expect(throws: VideoMutationAdmissionError.stale) { try await mutation.value } }
        #expect(counts.writes == writes && counts.drains == drains)
        #expect(await stream.publishingGeneration == freshGeneration)
        #expect(await stream.publishingError == nil)
        #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration.id == fresh.change.configuration.id)
        #expect(await !stream.isVideoMutationPending)
        await stream.close(); await connection.close()
    }

    @Test func guardedStaleBaselinePreservesNewerProbeAndPublication() async throws {
        let gate = ReplacementGate(), counts = AdmissionCounts(), observed = ReplacementFrames()
        let codec = VideoCodec(sessionFactory: { mode, codec in
            AdmissionSession(try mode.makeSession(codec), gate: gate, counts: counts)
        })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }, statisticsReader: { _, mon, _ in mon.msRTT = 2; return 0 }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            compressedVideoObserver: observed.record, allowsBandwidthProbes: true, probeWakeRunner: { _, _ in })
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let deadline = ContinuousClock.now + .seconds(2)
        while await stream.transportClockSnapshot == nil, ContinuousClock.now < deadline { await Task.yield() }
        let old = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        let current = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        let probe = try await stream.beginBandwidthProbe(bitRate: 100_000, publishingGeneration: generation)
        let writes = counts.writes, drains = counts.drains
        for selector in [SRTStream.VideoMutationExpectation.verified(publishingGeneration: generation, configuration: .init(old.change)),
                         .verified(publishingGeneration: generation + 1, configuration: .init(current.change))] {
            await #expect(throws: VideoMutationAdmissionError.stale) { try await stream.setVerifiedVideoBitRateWithReceipt(1_000_000, expecting: selector) }
        }
        await #expect(throws: VideoMutationAdmissionError.stale) {
            try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, expecting: .init(old.change))
        }
        #expect(counts.writes == writes && counts.drains == drains)
        #expect(await stream.bandwidthProbeSnapshot?.id == probe.id)
        #expect(await stream.bandwidthProbeSnapshot?.reason == nil)
        #expect(await !stream.isVideoMutationPending)
        #expect(await stream.verifiedVideoBitRateReceipt?.change.configuration.id == current.change.configuration.id)
        #expect(await stream.publishingGeneration == generation)
        #expect(await stream.publishingError == nil)
        await stream.finish(); await connection.close()
    }

    private func guardedFollowup(_ stream: SRTStream, rate: Int, receipt: SRTStream.VideoReplacementReceipt) async throws -> SRTStream.VideoBitRateReceipt {
        try await stream.setVerifiedVideoBitRateWithReceipt(rate, expecting: .replacement(receipt))
    }

    private func gatedStream(_ gate: ReplacementGate, observed: ReplacementFrames, transport: ReplacementTransport = ReplacementTransport(), audio: Bool = false, deferTransport: Bool = false, defect: String? = nil) async throws -> (SRTConnection, SRTStream, UInt64) {
        var count = 0
        let codec = VideoCodec(sessionFactory: { mode, codec in
            count += 1
            if count > 1, defect == "creation" { throw VTSessionError.failedToCreate(status: -91) }
            if count > 1, defect == "format" {
                let wrong = VideoCodec()
                wrong.settings = .init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false)
                return try mode.makeSession(wrong)
            }
            let native = try mode.makeSession(codec)
            return count == 1 ? GatedReplacementSession(native, gate: gate, status: defect == "drain" ? -77 : nil) : native
        })
        let connection = SRTConnection(socket: SRTSocket(sender: { transport.append($0); return Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            compressedVideoObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        // Missing audio holds TS startup only for lifecycle tests. This isolates
        // encoder reuse from the intentionally terminal cancellation of a socket send.
        await stream.setExpectedMedias(audio || deferTransport ? [.audio, .video] : [.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        if audio { try await appendReplacementAudio(stream, sampleTime: 0) }
        await stream.append(try replacementVideo(0))
        let deadline = ContinuousClock.now + .seconds(2)
        while observed.frames.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        try #require(observed.frames.count == 1)
        return (connection, stream, generation)
    }
    private var reduced: VideoCodecSettings { .init(videoSize: CGSize(width: 32, height: 32), allowFrameReordering: false) }

    @Test func stalledDrainKeepsIngressBoundedAndRejectsConflictingChanges() async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed)
        defer { gate.open() }
        _ = try await stream.setVerifiedVideoBitRateWithReceipt(900_000, publishingGeneration: generation)
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
        try await gate.waitForEntry()
        #expect(await stream.verifiedVideoBitRateReceipt == nil)
        await #expect(throws: SRTStream.VideoReplacementError.busy) {
            try await stream.replaceVideoSettings(reduced, publishingGeneration: generation)
        }
        await #expect(throws: SRTStream.VideoReplacementError.busy) { try await stream.setVideoSettings(reduced) }
        await #expect(throws: VideoBitRateUpdateError.sessionInvalidated) {
            try await stream.setVerifiedVideoBitRate(1_000_000, publishingGeneration: generation)
        }
        for frame in 1...30 { await stream.append(try replacementVideo(frame)) }
        #expect(observed.frames.count == 1)
        gate.open()
        let receipt = try await change.value
        #expect(receipt.rawVideoFramesDropped >= 27 && receipt.rawVideoFramesDropped <= 28)
        await stream.finish()
        #expect(await stream.publishingError == nil)
        #expect(observed.frames.count + Int(receipt.rawVideoFramesDropped) == 31)
        #expect(observed.frames.last?.sourcePTS == CMTime(value: 30, timescale: 30))
        #expect(observed.frames.dropFirst().allSatisfy { $0.width == 32 })
        await connection.close()
    }

    @Test(arguments: ["close", "cancel", "deadline", "finish"])
    func interruptedDrainJoinsBeforeReuse(action: String) async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed, deferTransport: true)
        defer { gate.open() }
        let done = ReplacementDone()
        let change = Task {
            let result = await Result { try await stream.replaceVideoSettings(reduced,
                publishingGeneration: generation, timeout: action == "deadline" ? .milliseconds(40) : .seconds(2)) }
            done.set()
            return result
        }
        try await gate.waitForEntry()
        var finishing: Task<Void, Never>?
        let finishDone = ReplacementDone()
        switch action {
        case "close": await stream.close()
        case "cancel": change.cancel()
        case "finish": finishing = Task { await stream.finish(); finishDone.set() }
        default: break
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while await stream.readyState != .idle, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await stream.readyState == .idle)
        #expect(!done.value, "Caller must still own and join blocked native completion")
        if action == "finish" { #expect(!finishDone.value, "Finish must also join native completion") }
        await stream.publish()
        #expect(await stream.readyState == .idle)
        #expect(observed.frames.count == 1)
        gate.open()
        let result = await change.value
        if case .success = result { Issue.record("Interrupted replacement returned a receipt") }
        if case .failure(let error) = result {
            #expect((error as? SRTStream.VideoReplacementError) == (action == "deadline" ? .deadline : .interrupted))
        }
        await finishing?.value
        if action == "finish" { #expect(finishDone.value) }
        #expect(done.value)
        if action == "close" {
            await stream.setExpectedMedias([.video]); await stream.publish()
            let resumed = await stream.publishingGeneration
            if resumed == nil {
                let streamState = await stream.readyState
                let streamError = await stream.publishingError
                let muxerError = await stream.muxerError
                let connected = await connection.connected
                let connectionError = await connection.publishingError
                Issue.record("Restart unavailable: state=\(streamState) stream=\(String(describing: streamError)) muxer=\(String(describing: muxerError)) connected=\(connected) connection=\(String(describing: connectionError))")
            }
            #expect(resumed != generation)
            await stream.append(try replacementVideo(1)); await stream.finish()
            #expect(await stream.publishingError == nil)
            #expect(observed.frames.last?.width == 64)
        }
        await connection.close()
    }

    @Test func noNewOutputCannotBeMistakenForAppliedProfile() async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        gate.open()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed)
        await #expect(throws: SRTStream.VideoReplacementError.deadline) {
            try await stream.replaceVideoSettings(reduced, publishingGeneration: generation, timeout: .milliseconds(40))
        }
        #expect(observed.frames.count == 1)
        #expect(await stream.readyState == .idle)
        #expect(await stream.publishingError != nil)
        await connection.close()
    }

    @Test func audioContinuesWhileNativeVideoDrainIsBlocked() async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames(), transport = ReplacementTransport()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed, transport: transport, audio: true)
        defer { gate.open() }
        let initialDeadline = ContinuousClock.now + .seconds(1)
        while transport.audioPackets == 0 && ContinuousClock.now < initialDeadline { await Task.yield() }
        try #require(transport.audioPackets > 0)
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
        try await gate.waitForEntry()
        let before = transport.audioPackets
        try await appendReplacementAudio(stream, sampleTime: 4096)
        let audioDeadline = ContinuousClock.now + .seconds(1)
        while transport.audioPackets <= before && ContinuousClock.now < audioDeadline { await Task.yield() }
        #expect(transport.audioPackets > before)
        #expect(observed.frames.count == 1)
        await stream.append(try replacementVideo(1))
        gate.open(); _ = try await change.value
        await stream.finish(); #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test(arguments: ["drain", "creation", "format"])
    func failedNativeReplacementNeverReturnsReceipt(defect: String) async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed, defect: defect)
        defer { gate.open() }
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
        try await gate.waitForEntry()
        await stream.append(try replacementVideo(1))
        gate.open()
        do { _ = try await change.value; Issue.record("Native defect produced a profile receipt") } catch {}
        #expect(observed.frames.count == 1)
        #expect(await stream.readyState == .idle)
        let error = await stream.publishingError
        if defect == "drain" { #expect(error == .codecFailed(status: -77)) }
        else if defect == "creation" { #expect(error == .codecFailed(status: -91)) }
        else { #expect(error == .outputTerminated(boundary: "SRT video replacement output")) }
        await connection.close()
    }

    @Test func preflightRejectsStaleGenerationAndUnsafeDimensionsWithoutStoppingLiveEncoder() async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed)
        defer { gate.open() }
        await #expect(throws: SRTStream.VideoReplacementError.notEncoding) {
            try await stream.replaceVideoSettings(reduced, publishingGeneration: generation &+ 1)
        }
        for width in [Double.nan, .infinity, -1, 0, 17, 8193] {
            var bad = reduced; bad.videoSize.width = width
            await #expect(throws: SRTStream.VideoReplacementError.invalidSettings) {
                try await stream.replaceVideoSettings(bad, publishingGeneration: generation)
            }
        }
        var reordered = reduced; reordered.allowFrameReordering = true
        await #expect(throws: SRTStream.VideoReplacementError.invalidSettings) {
            try await stream.replaceVideoSettings(reordered, publishingGeneration: generation)
        }
        #expect(await stream.videoSettings.videoSize.width == 64)
        #expect(await stream.publishingError == nil)
        await stream.append(try replacementVideo(1))
        gate.open(); await stream.finish()
        #expect(observed.frames.map(\.width) == [64, 64])
        #expect(await stream.publishingError == nil)
        await connection.close()
    }

    @Test(arguments: ["cancel", "close", "restart", "cancelAfterRestart", "invalidate"])
    func finalReceiptBoundaryRechecksOwnershipAfterNativeTaskHasJoined(action: String) async throws {
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed, deferTransport: true)
        defer { gate.open() }
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
        try await gate.waitForEntry()
        await stream.append(try replacementVideo(1)); gate.open()
        let receipt = try await change.value
        if action == "invalidate" {
            try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        } else if action != "cancel" { await stream.close() }
        let restarted = action == "restart" || action == "cancelAfterRestart"
        if restarted {
            await stream.setExpectedMedias([.video]); await stream.publish()
            #expect(await stream.publishingGeneration != generation)
        }
        let current = await stream.publishingGeneration
        let final = Task {
            if action == "cancel" || action == "cancelAfterRestart" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try await stream.acceptVideoReplacementReceipt(receipt)
        }
        do { _ = try await final.value; Issue.record("Stale/cancelled return boundary produced a receipt") } catch {}
        if restarted || action == "invalidate" {
            #expect(await stream.publishingGeneration == current)
            #expect(await stream.publishingError == nil)
        } else { #expect(await stream.readyState == .idle) }
        await connection.close()
    }

    @Test(arguments: [false, true])
    func compressedPassthroughCannotCrossReplacementBoundary(duringChange: Bool) async throws {
        let codec = VideoCodec()
        codec.settings = .init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false)
        let output = codec.outputStream
        codec.startRunning(); codec.append(try replacementVideo(1))
        let complete = codec.makeCompletion(); await Task.detached { complete() }.value
        codec.stopRunning()
        var iterator = output.makeAsyncIterator()
        let compressed = try #require(await iterator.next())
        let gate = ReplacementGate(), observed = ReplacementFrames()
        let (connection, stream, generation) = try await gatedStream(gate, observed: observed)
        defer { gate.open() }
        if duringChange {
            let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
            try await gate.waitForEntry()
            await stream.append(compressed)
            gate.open()
            do { _ = try await change.value; Issue.record("Passthrough crossed replacement boundary") } catch {}
            #expect(await stream.publishingError == .outputTerminated(boundary: "SRT video replacement passthrough"))
            #expect(observed.frames.count == 1)
        } else {
            await stream.append(compressed)
            await #expect(throws: SRTStream.VideoReplacementError.notEncoding) {
                try await stream.replaceVideoSettings(reduced, publishingGeneration: generation)
            }
            #expect(await stream.publishingError == nil)
            gate.open(); await stream.finish()
        }
        await connection.close()
    }

    @Test(arguments: ["success", "failure", "close"])
    func earlyReplacementOutputRequiresSuccessfulJoinedSubmission(outcome: String) async throws {
        let fixtureCodec = VideoCodec()
        fixtureCodec.settings = reduced
        let fixtureOutput = fixtureCodec.outputStream
        fixtureCodec.startRunning(); fixtureCodec.append(try replacementVideo(1))
        let complete = fixtureCodec.makeCompletion(); await Task.detached { complete() }.value
        fixtureCodec.stopRunning()
        var iterator = fixtureOutput.makeAsyncIterator()
        let fixture = try #require(await iterator.next())
        let gate = ReplacementGate(), done = ReplacementDone(), observed = ReplacementFrames()
        defer { gate.open() }
        var creations = 0
        let codec = VideoCodec(sessionFactory: { mode, codec in
            creations += 1
            return creations == 1 ? try mode.makeSession(codec) : EarlyReplacementSession(
                sample: fixture, gate: gate, fails: outcome == "failure")
        })
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec),
            compressedVideoObserver: observed.record)
        await connection.addStream(stream); try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let ready = ContinuousClock.now + .seconds(1)
        while observed.frames.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(observed.frames.count == 1)
        let change = Task {
            defer { done.set() }
            return try await stream.replaceVideoSettings(reduced, publishingGeneration: generation)
        }
        let staged = ContinuousClock.now + .seconds(1)
        while await stream.videoSettings.videoSize.width != 32, ContinuousClock.now < staged { await Task.yield() }
        try #require(await stream.videoSettings.videoSize.width == 32)
        await stream.append(try replacementVideo(1)); try await gate.waitForEntry()
        // Let the encoded consumer reach its join without releasing native convert.
        try await Task.sleep(for: .milliseconds(25))
        #expect(!done.value && observed.frames.count == 1)
        var closing: Task<Void, Never>?
        if outcome == "close" {
            closing = Task { await stream.close() }
            let deadline = ContinuousClock.now + .seconds(1)
            while await stream.readyState != .idle, ContinuousClock.now < deadline { await Task.yield() }
            #expect(await stream.readyState == .idle)
        }
        gate.open()
        if outcome == "success" {
            let receipt = try await change.value
            #expect(receipt.lastOldSourcePTS == .zero)
            #expect(receipt.firstNewSourcePTS == CMTime(value: 1, timescale: 30))
            #expect(receipt.width == 32 && observed.frames.count == 2)
            await stream.finish()
            #expect(await stream.publishingError == nil)
        } else {
            do { _ = try await change.value; Issue.record("Unsuccessful submission produced a replacement receipt") } catch {}
            #expect(observed.frames.count == 1)
        }
        await closing?.value
        await stream.close(); await connection.close()
    }

    @Test func invalidatedRevisionCannotAcknowledgeItsPendingFirstOutput() async throws {
        let fixtureCodec = VideoCodec()
        fixtureCodec.settings = reduced
        let fixtureOutput = fixtureCodec.outputStream
        fixtureCodec.startRunning(); fixtureCodec.append(try replacementVideo(1))
        let complete = fixtureCodec.makeCompletion(); await Task.detached { complete() }.value
        fixtureCodec.stopRunning()
        var fixtureIterator = fixtureOutput.makeAsyncIterator()
        let delayed = DelayedReplacementOutput(sample: try #require(await fixtureIterator.next()))
        var creations = 0
        let codec = VideoCodec(sessionFactory: { mode, codec in
            creations += 1
            return creations == 1 ? try mode.makeSession(codec) : delayed
        })
        let invalidation = ReplacementInvalidation(codec)
        let observed = ReplacementFrames()
        let connection = SRTConnection(socket: SRTSocket(sender: { Int32($0.count) }))
        let stream = SRTStream(connection: connection, outgoing: OutgoingStream(videoCodec: codec), compressedVideoObserver: observed.record)
        await connection.addStream(stream)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        try await stream.setVideoSettings(.init(videoSize: CGSize(width: 64, height: 64), allowFrameReordering: false))
        await stream.setExpectedMedias([.video]); await stream.publish()
        let generation = try #require(await stream.publishingGeneration)
        await stream.append(try replacementVideo(0))
        let ready = ContinuousClock.now + .seconds(1)
        while observed.frames.isEmpty && ContinuousClock.now < ready { await Task.yield() }
        try #require(observed.frames.count == 1)
        let change = Task { try await stream.replaceVideoSettings(reduced, publishingGeneration: generation) }
        let staged = ContinuousClock.now + .seconds(1)
        while await stream.videoSettings.videoSize.width != 32, ContinuousClock.now < staged { await Task.yield() }
        await stream.append(try replacementVideo(1))
        let submitted = ContinuousClock.now + .seconds(1)
        while !delayed.submitted && ContinuousClock.now < submitted { await Task.yield() }
        try #require(delayed.submitted)
        // An actor read runs after consumeVideoInput has recorded its first submission.
        _ = await stream.videoSettings
        invalidation.request() // Same thread-safe revision path as codec notifications.
        delayed.emit()
        do { _ = try await change.value; Issue.record("Obsolete encoder output produced a receipt") } catch {}
        #expect(observed.frames.count == 1, "Obsolete first output must fail before mux observation")
        #expect(await stream.publishingError == .outputTerminated(boundary: "SRT video replacement output"))
        #expect(await stream.readyState == .idle)
        await connection.close()
    }

}

private final class ReplacementFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SRTStream.CompressedVideoFrame] = []
    private var times: [Double] = []
    var frames: [SRTStream.CompressedVideoFrame] { lock.withLock { values } }
    var observedTimes: [Double] { lock.withLock { times } }
    func record(_ frame: SRTStream.CompressedVideoFrame) {
        lock.withLock { values.append(frame); times.append(ProcessInfo.processInfo.systemUptime) }
    }
}
private func replacementVideo(_ frame: Int) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let image = try #require(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    if let bytes = CVPixelBufferGetBaseAddress(image) { memset(bytes, Int32(frame), CVPixelBufferGetDataSize(image)) }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}


private final class ReplacementGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    func pause() -> Bool {
        lock.withLock { entered = true }
        return gate.wait(timeout: .now() + 3) == .success
    }
    func open() { gate.signal() }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !lock.withLock({ entered }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(lock.withLock { entered })
    }
}
private final class GatedReplacementSession: VTSessionConvertible {
    let native: any VTSessionConvertible
    let gate: ReplacementGate
    let status: OSStatus?
    init(_ native: any VTSessionConvertible, gate: ReplacementGate, status: OSStatus? = nil) {
        self.native = native; self.gate = gate; self.status = status
    }
    func setOption(_ option: VTSessionOption) -> OSStatus { native.setOption(option) }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { native.copyOption(key) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { native.setOptions(options) }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        try native.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: encoderCompletionObserver)
    }
    func completeFrames() -> OSStatus {
        guard gate.pause() else { return -999 }
        let actual = native.completeFrames()
        return status ?? actual
    }
    func invalidate() { native.invalidate() }
}
private final class ReplacementDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
private extension Result where Failure == Swift.Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

private final class ReplacementTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var audioPackets: Int {
        let snapshot = lock.withLock { bytes }
        return stride(from: 0, to: snapshot.count - snapshot.count % 188, by: 188).filter { offset in
            guard let packet = TSPacket(data: snapshot.subdata(in: offset..<offset + 188)) else { return false }
            return packet.pid == TSWriter.defaultAudioPID && packet.payloadUnitStartIndicator
        }.count
    }
}
private func appendReplacementAudio(_ stream: SRTStream, sampleTime: Int64) async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    pcm.frameLength = 4096
    if let data = pcm.floatChannelData { memset(data[0], 0, 4096 * MemoryLayout<Float>.size) }
    await stream.append(pcm, when: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: Double(sampleTime) / 48000),
        sampleTime: sampleTime, atRate: 48000))
}

/// Notification invalidation is the only thread-safe codec action this wrapper exposes.
private final class ReplacementInvalidation: @unchecked Sendable {
    private weak var codec: VideoCodec?
    init(_ codec: VideoCodec) { self.codec = codec }
    func request() { codec?.requestSessionInvalidation() }
}
private final class DelayedReplacementOutput: VTSessionConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private let sample: CMSampleBuffer
    private var pending: (PublishingQueue<CMSampleBuffer>?, VideoEncoderCompletionObserver?)?
    init(sample: CMSampleBuffer) { self.sample = sample }
    var submitted: Bool { lock.withLock { pending != nil } }
    func setOption(_ option: VTSessionOption) -> OSStatus { noErr }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        #expect(sampleBuffer.presentationTimeStamp == sample.presentationTimeStamp)
        lock.withLock { pending = (continuation, encoderCompletionObserver) }
    }
    func emit() {
        let work = lock.withLock { let work = pending; pending = nil; return work }
        work?.1?(sample.presentationTimeStamp, sample.presentationTimeStamp)
        _ = work?.0?.yield(sample, byteCount: CMSampleBufferGetTotalSampleSize(sample))
    }
    func completeFrames() -> OSStatus { noErr }
    func invalidate() {}
}

private final class EarlyReplacementSession: VTSessionConvertible {
    let sample: CMSampleBuffer, gate: ReplacementGate, fails: Bool
    init(sample: CMSampleBuffer, gate: ReplacementGate, fails: Bool) {
        self.sample = sample; self.gate = gate; self.fails = fails
    }
    func setOption(_ option: VTSessionOption) -> OSStatus { noErr }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { (noErr, nil) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
    func convert(_ input: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?,
                 encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        encoderCompletionObserver?(input.presentationTimeStamp, sample.presentationTimeStamp)
        _ = continuation?.yield(sample, byteCount: sample.totalSampleSize)
        #expect(gate.pause(), "Native gate must be released explicitly")
        if fails { throw VTSessionError.failedToConvert(status: -73) }
    }
    func completeFrames() -> OSStatus { noErr }
    func invalidate() {}
}

private final class AdmissionCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites = 0, storedDrains = 0
    var writes: Int { lock.withLock { storedWrites } }
    var drains: Int { lock.withLock { storedDrains } }
    func wrote() { lock.withLock { storedWrites += 1 } }
    func drained() { lock.withLock { storedDrains += 1 } }
}
private final class AdmissionSession: VTSessionConvertible {
    let native: any VTSessionConvertible, gate: ReplacementGate, counts: AdmissionCounts
    init(_ native: any VTSessionConvertible, gate: ReplacementGate, counts: AdmissionCounts) {
        self.native = native; self.gate = gate; self.counts = counts
    }
    func setOption(_ option: VTSessionOption) -> OSStatus { counts.wrote(); return native.setOption(option) }
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) { native.copyOption(key) }
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { native.setOptions(options) }
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        if sampleBuffer.presentationTimeStamp == CMTime(value: 1, timescale: 30) { _ = gate.pause() }
        try native.convert(sampleBuffer, continuation: continuation, encoderCompletionObserver: encoderCompletionObserver)
    }
    func completeFrames() -> OSStatus { counts.drained(); return native.completeFrames() }
    func invalidate() { native.invalidate() }
}

private actor AdmissionJoinGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        try #require(entered)
    }
}
