@preconcurrency import AVFoundation
import Foundation
import ScorebugMedia
import SDKProbe

private func emit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func clockEvidence(_ clock: PublishingTransportClock?) -> Any {
    guard let clock else { return NSNull() }
    let origin = clock.sourceOrigin
    return ["publishingGeneration": String(clock.publishingGeneration),
            "sourceOrigin": ["value": String(origin.value), "timescale": origin.timescale,
                             "epoch": String(origin.epoch), "flags": origin.flags.rawValue],
            "timescale": PublishingTransportClock.timescale,
            "presentationLead": String(PublishingTransportClock.presentationLead),
            "wireModulus": String(PublishingTransportClock.wireModulus)] as [String: Any]
}

private func timeEvidence(_ time: CMTime) -> [String: Any] {
    ["value": String(time.value), "timescale": time.timescale,
     "epoch": String(time.epoch), "flags": time.flags.rawValue]
}

private func configurationEvidence(_ configuration: SDKProbe.EncoderConfiguration) -> [String: Any] {
    ["id": configuration.id.uuidString, "encoderSessionID": configuration.encoderSessionID.uuidString,
     "bitRate": configuration.bitRate]
}

private func receiptEvidence(_ receipt: SDKProbe.BitRateChangeReceipt) -> [String: Any] {
    ["publishingGeneration": String(receipt.publishingGeneration),
     "configuration": configurationEvidence(receipt.configuration), "acceptedAt": receipt.acceptedAt,
     "lastSubmittedSourcePTS": receipt.lastSubmittedSourcePTS.map(timeEvidence) as Any? ?? NSNull()]
}

/// Only bounded immutable scalars cross the native callback; JSON is produced after tool stop.
private final class EncoderEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SDKProbe.EncoderFrame] = []
    private var overflow = false
    private var submissions: [SDKProbe.EncoderSubmission] = []
    private var submissionOverflow = false
    func record(_ call: SDKProbe.EncoderSubmission) {
        lock.withLock {
            guard submissions.count < 512 else { submissionOverflow = true; return }
            submissions.append(call)
        }
    }
    func record(_ frame: SDKProbe.EncoderFrame) {
        lock.withLock {
            guard frames.count < 512 else { overflow = true; return }
            frames.append(frame)
        }
    }
    func snapshot() -> [String: Any] {
        let (records, exceeded, calls, callsExceeded) = lock.withLock { (frames, overflow, submissions, submissionOverflow) }
        return ["submissionOverflow": callsExceeded, "submissionCalls": calls.map { call in
            ["sourcePTS": timeEvidence(call.sourcePTS), "encoderSessionID": call.encoderSessionID.uuidString,
             "startedAt": call.startedAt, "returnedAt": call.returnedAt, "status": call.status,
             "selectionQueriedAfterPreparation": encoderHardwareSelectionEvidence(call.selectionQueriedAfterPreparation) as Any? ?? NSNull()] as [String: Any]
        }, "overflow": exceeded, "frames": records.map { frame in
            ["sourcePTS": timeEvidence(frame.sourcePTS), "outputPTS": timeEvidence(frame.outputPTS),
             "encoderSessionID": frame.encoderSessionID.uuidString,
             "configuration": frame.configuration.map(configurationEvidence) as Any? ?? NSNull(),
             "submittedAt": frame.submittedAt, "completedAt": frame.completedAt] as [String: Any]
        }]
    }
}

private func configurationEvidence(_ configuration: VideoEncodingConfiguration) -> [String: Any] {
    ["id": configuration.id.uuidString, "encoderSessionID": configuration.encoderSessionID.uuidString,
     "bitRate": configuration.bitRate]
}

private func coverageEvidence(_ coverage: VideoEncodingCoverage) -> [String: Any] {
    switch coverage {
    case .unavailable: return ["state": "unavailable"]
    case .unverified: return ["state": "unverified"]
    case .mixed: return ["state": "mixed"]
    case .verified(let configuration): return ["state": "verified", "configuration": configurationEvidence(configuration)]
    }
}

private func scopeEvidence(_ scope: VideoFrameObservationScope) -> [String: Any] {
    ["recordingID": scope.recordingID, "matchID": scope.matchID,
     "broadcastGeneration": scope.broadcastGeneration, "publishingAttemptID": scope.publishingAttemptID.uuidString,
     "appliedProfileRevision": String(scope.appliedProfileRevision)]
}
private func pressureIntervalEvidence(_ value: LiveIngressPressureInterval?) -> Any {
    guard let value else { return NSNull() }
    return ["start": value.start, "end": value.end, "itemSeconds": value.itemSeconds,
        "byteSeconds": value.byteSeconds, "maxPressureSeconds": value.maxPressureSeconds,
        "meanMaxPressure": value.meanMaxPressure]
}
private func pressureEvidence(_ snapshot: LiveIngressObservationSnapshot?) -> Any {
    guard let snapshot else { return NSNull() }
    let pressure = snapshot.pressure
    return ["scope": scopeEvidence(snapshot.scope), "coveredThrough": pressure.coveredThrough,
        "isClosed": pressure.isClosed, "isQuarantined": pressure.isQuarantined, "omittedStates": String(pressure.omittedStates),
        "states": pressure.states.map { ["at": $0.at, "itemFraction": $0.itemFraction, "byteFraction": $0.byteFraction, "phase": $0.phase.rawValue] as [String: Any] }]
}

private func transportIntervalEvidence(_ value: PublishingTransportInterval?) -> Any {
    guard let value else { return NSNull() }
    return ["publishingGeneration": String(value.publishingGeneration), "start": value.start, "end": value.end,
        "enclosingStart": value.enclosingStart, "enclosingEnd": value.enclosingEnd, "sampleCount": value.sampleCount,
        "enclosingSentBytes": String(value.enclosingSentBytes), "enclosingRetransmittedBytes": String(value.enclosingRetransmittedBytes),
        "enclosingDroppedPackets": String(value.enclosingDroppedPackets), "meanBufferedBytes": value.meanBufferedBytes,
        "meanBufferMilliseconds": value.meanBufferMilliseconds, "meanRTTMilliseconds": value.meanRTTMilliseconds,
        "enclosingMaximumBufferedBytes": String(value.enclosingMaximumBufferedBytes),
        "enclosingMaximumBufferMilliseconds": String(value.enclosingMaximumBufferMilliseconds),
        "enclosingMaximumRTTMilliseconds": value.enclosingMaximumRTTMilliseconds]
}
private final class TransportEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = PublishingTransportStatisticsTracker()
    func observe(_ sample: PublishingTransportStatistics?) -> PublishingTransportStatisticsSnapshot {
        lock.withLock { tracker.observe(sample); return tracker.snapshot }
    }
    func close() -> PublishingTransportStatisticsSnapshot {
        lock.withLock { tracker.close(); return tracker.snapshot }
    }
}

private func sourceEvidence(_ history: VideoSourceHistorySnapshot?, clock: PublishingTransportClock?,
                            receipt: SDKProbe.BitRateChangeReceipt?, aggregate: VideoFrameObservationSnapshot?, ingress: LiveIngressObservationSnapshot?, transport: PublishingTransportStatisticsSnapshot?) -> Any {
    guard let history else { return NSNull() }
    var probes: [[String: Any]] = []
    if let clock, let boundary = receipt?.lastSubmittedSourcePTS,
       let index = history.encoded.firstIndex(where: { CMTimeCompare($0.sourcePTS, boundary) == 0 }),
       index > 0, index + 150 < history.encoded.count {
        // Finite fixture probes use declared receiver endpoints, not a production
        // worker report. Decoded barcodes independently validate normal media.
        func ticks(_ i: Int) -> Int64 {
            CMTimeConvertScale(CMTimeSubtract(history.encoded[i].sourcePTS, clock.sourceOrigin),
                timescale: 90_000, method: .roundTowardNegativeInfinity).value + 9_000
        }
        for (name, previous, end) in [("before", 0, index), ("after", index, index + 150),
                                      ("crossing", index - 1, index + 150)] {
            if let interval = PublishingSourceInterval.match(history: history, clock: clock, relayOriginPTS: 0,
                previousDecodedPTS: ticks(previous), firstDecodedPTS: ticks(previous + 1),
                lastDecodedPTS: ticks(end), decodedFrames: Int64(end - previous)) {
                probes.append(["name": name, "sourceStartExclusive": timeEvidence(interval.sourceStartExclusive),
                    "sourceEndInclusive": timeEvidence(interval.sourceEndInclusive),
                    "capturedFrames": interval.capturedFrames, "encodedFrames": interval.encodedFrames,
                    "decodedFrames": interval.decodedFrames, "leadingMissingEncodedFrames": interval.leadingMissingEncodedFrames,
                    "coverage": coverageEvidence(interval.encodingCoverage),
                    "captureBoundaryStartTime": interval.captureBoundaryStartTime,
                    "captureBoundaryEndTime": interval.captureBoundaryEndTime,
                    "ingressPressure": pressureIntervalEvidence(ingress.flatMap { interval.ingressPressure(in: $0) }),
                    "transportInterval": transportIntervalEvidence(transport?.interval(from: interval.captureBoundaryStartTime,
                        to: interval.captureBoundaryEndTime))])
            }
        }
    }
    let windows = aggregate.map { $0.completed + [$0.current] } ?? []
    return ["scope": scopeEvidence(history.scope),
            "capture": history.capture.map { ["sourcePTS": timeEvidence($0.sourcePTS), "observedAt": $0.observedAt] as [String: Any] },
            "aggregateEncodedCallbacks": String(windows.reduce(UInt64(0)) { $0 + $1.encodedVideo.callbackCount }),
            "aggregateCaptureCallbacks": String(windows.reduce(UInt64(0)) { $0 + $1.captureVideo.callbackCount }),
            "aggregateValid": aggregate.map { $0.isClosed && $0.invalidity.isEmpty && $0.omittedCompletedWindowCount == 0 && $0.rejectedClockOperationCount == 0 } ?? false,
            "isClosed": history.isClosed, "invalidity": history.invalidity.map { String(describing: $0) } as Any? ?? NSNull(),
            "omittedCaptureFrames": String(history.omittedCaptureFrames), "omittedEncodedFrames": String(history.omittedEncodedFrames),
            "captureFrameCount": history.capture.count, "intervalProbes": probes,
            "encoded": history.encoded.map { frame -> [String: Any] in
                let encoding: Any = frame.encoding.map { value in
                    ["encoderSessionID": value.encoderSessionID.uuidString,
                     "configuration": value.configuration.map(configurationEvidence) as Any? ?? NSNull(),
                     "submittedAt": value.submittedAt, "completedAt": value.completedAt] as [String: Any]
                } ?? NSNull()
                return ["sourcePTS": timeEvidence(frame.sourcePTS), "observedAt": frame.observedAt, "encoding": encoding]
            }] as [String: Any]
}

private func statisticsEvidence(_ sample: PublishingTransportStatistics?) -> Any {
    guard let sample else { return NSNull() }
    return ["publishingGeneration": String(sample.publishingGeneration), "sampledAt": sample.sampledAt,
            "elapsedMilliseconds": String(sample.elapsedMilliseconds), "sentBytes": String(sample.sentBytes),
            "retransmittedBytes": String(sample.retransmittedBytes), "droppedPackets": String(sample.droppedPackets),
            "rttMilliseconds": sample.rttMilliseconds, "estimatedBandwidthMbps": sample.estimatedBandwidthMbps,
            "senderBufferedBytes": String(sample.senderBufferedBytes),
            "senderBufferMilliseconds": String(sample.senderBufferMilliseconds),
            "availableSenderBytes": String(sample.availableSenderBytes)] as [String: Any]
}

private func windowEvidence(_ window: PublishingTransportWindow?) -> Any {
    guard let w = window else { return NSNull() }
    return ["publishingGeneration": String(w.publishingGeneration), "start": w.start, "end": w.end,
            "sampleCount": w.sampleCount, "sentBytes": String(w.sentBytes),
            "retransmittedBytes": String(w.retransmittedBytes), "droppedPackets": String(w.droppedPackets),
            "meanBufferedBytes": w.meanBufferedBytes, "meanBufferMilliseconds": w.meanBufferMilliseconds,
            "meanRTTMilliseconds": w.meanRTTMilliseconds, "maximumBufferedBytes": String(w.maximumBufferedBytes),
            "maximumBufferMilliseconds": String(w.maximumBufferMilliseconds),
            "maximumRTTMilliseconds": w.maximumRTTMilliseconds] as [String: Any]
}

private enum Failure: Error { case arguments, missingTracks, reader, archiveOverflow, pcm }

private func sealedTransportEvidence(_ trace: TransportSendTrace) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace.seal()))
}

private final class PublisherHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    private var firstFailure: SDKProbe.HealthSnapshot?
    func observe(_ snapshot: SDKProbe.HealthSnapshot) {
        guard !snapshot.isPublishing else { return }
        lock.withLock { if firstFailure == nil { firstFailure = snapshot } }
    }
    var evidence: Any {
        guard let snapshot = lock.withLock({ firstFailure }) else { return NSNull() }
        return ["connected": snapshot.connected, "streamPublishing": snapshot.streamPublishing,
            "muxerError": snapshot.muxerError.map { String(describing: $0) } as Any? ?? NSNull(),
            "streamError": snapshot.streamError.map { String(describing: $0) } as Any? ?? NSNull(),
            "transportError": snapshot.transportError.map { String(describing: $0) } as Any? ?? NSNull()] as [String: Any]
    }
    var isFailed: Bool { lock.withLock { failed } }
    func fail() { lock.withLock { failed = true } }
}

/// The file reader is driven by the real-time loop below. This source exercises
/// the same prepare/start/quiesce contract used by the iPhone camera adapter.
private final class FixtureCaptureSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let origin: CMTime
    private var callbacks: CaptureSourceCallbacks?
    private var delivering = false
    init(origin: CMTime) { self.origin = origin }
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime {
        lock.withLock { self.callbacks = callbacks }
        return origin
    }
    func start() async throws { lock.withLock { delivering = true } }
    func stop() async { lock.withLock { delivering = false; callbacks = nil } }
    func submit(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock {
            guard delivering, let callbacks else { return false }
            callbacks.sample(sample)
            return true
        }
    }
    func fail() { lock.withLock { callbacks?.event(.failed) } }
}

@main struct DualOutputSmoke {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            // Network exercise is deliberately restricted to an owned local sink.
            guard (3...5).contains(args.count) else { throw Failure.arguments }
            let timestampOffset = args.count >= 4 ? Double(args[3]) : 0
            guard let timestampOffset, timestampOffset.isFinite,
                  timestampOffset >= 0, timestampOffset <= 86_400 else { throw Failure.arguments }
            let configuration = try DualOutputConfiguration(profileID: args.count == 5 ? args[4] : "1080p30")
            let url: URL?
            if args[2] == "record-only" { url = nil }
            else {
                guard let candidate = URL(string: args[2]), candidate.scheme == "srt",
                      candidate.host == "127.0.0.1", candidate.port != nil else { throw Failure.arguments }
                url = candidate
            }
            try await run(source: URL(fileURLWithPath: args[0]), directory: URL(fileURLWithPath: args[1]),
                          url: url, timestampOffset: timestampOffset, configuration: configuration)
        } catch {
            try? emit(["event": "failed", "reason": String(describing: error)])
            exit(1)
        }
    }

    private static func retimed(_ sample: CMSampleBuffer?, by offset: Double) throws -> CMSampleBuffer? {
        guard let sample, offset != 0 else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
            entriesNeededOut: &count) == noErr, count > 0 else { throw Failure.reader }
        var timing = Array(repeating: CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
            arrayToFill: &timing, entriesNeededOut: nil) == noErr else { throw Failure.reader }
        let shift = CMTime(seconds: offset, preferredTimescale: 1_000_000_000)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeConvertScale(timing[index].presentationTimeStamp + shift,
                timescale: 1_000_000_000, method: .default)
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeConvertScale(timing[index].decodeTimeStamp + shift,
                    timescale: 1_000_000_000, method: .default)
            }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result) == noErr,
            let result else { throw Failure.reader }
        return result
    }

    private static func run(source: URL, directory: URL, url: URL?, timestampOffset: Double,
                            configuration: DualOutputConfiguration) async throws {
        try emit(["event": "media-configuration", "liveProfile": configuration.liveProfile.rawValue,
            "width": configuration.liveProfile.width, "height": configuration.liveProfile.height,
            "liveBitRate": configuration.liveProfile.bitRate, "changedBitRate": configuration.changedBitRate,
            "archiveBitRate": configuration.archiveProfile.videoBitRate,
            "liveQueueMaxBytes": configuration.liveQueueMaxBytes,
            "archiveQueueMaxBytes": configuration.archiveQueueMaxBytes])
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.missingTracks }
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let audio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(video), reader.canAdd(audio) else { throw Failure.reader }
        reader.add(video); reader.add(audio)
        guard reader.startReading() else { throw Failure.reader }
        var nextVideo = try retimed(video.copyNextSampleBuffer(), by: timestampOffset)
        var nextAudio = try retimed(audio.copyNextSampleBuffer(), by: timestampOffset)
        guard let firstVideo = nextVideo, let firstAudio = nextAudio else { throw Failure.missingTracks }
        let origin = min(firstVideo.presentationTimeStamp, firstAudio.presentationTimeStamp)
        let originSeconds = origin.seconds
        let observations = try url.map { _ in
            try VideoFrameObservationOwner(scope: .init(recordingID: "dual-output", matchID: "fixture",
                broadcastGeneration: 1, publishingAttemptID: UUID(), appliedProfileRevision: 1), sourceHistoryCapacity: 512)
        }
        let archive = try SegmentedArchiveWriter(directory: directory, profile: configuration.archiveProfile)
        let archiveSession = try RecordingSession(sink: SegmentedArchiveSink(writer: archive),
            maxBytes: configuration.archiveQueueMaxBytes)
        let captureSource = FixtureCaptureSource(origin: origin)
        let recording = CaptureRecording(source: captureSource, session: archiveSession)
        try await recording.start()
        let ingressConfiguration = observations.map { owner in
            LiveIngressObservationConfiguration(scope: owner.snapshot.scope, monotonicAnchor: owner.snapshot.monotonicAnchor,
                initialPhase: .startup)
        }
        let liveQueue = try BoundedMailbox<CapturedMediaSample>(maxItems: 8, maxBytes: configuration.liveQueueMaxBytes,
            overflowPolicy: .dropOldest, ingressObservation: ingressConfiguration)
        let publisherTask = Task.detached {
            guard let url else {
                liveQueue.cancel()
                try emit(["event": "publisher-disabled"])
                return
            }
            let encoderEvidence = EncoderEvidence()
            let health = PublisherHealth()
            let transportSends = TransportSendTrace()
            let publisher = SRTMediaPublisher(url: url, observations: observations, encoderConfigurationObserver: { encoderEvidence.record($0) },
                videoProfile: configuration.liveProfile, healthObserver: { health.observe($0) },
                transportSendObserver: { transportSends.record($0) },
                encoderSubmissionObserver: { encoderEvidence.record($0) })
            var publishedVideo = 0
            var publishedAudio = 0
            var changed = false
            var acceptedReceipt: SDKProbe.BitRateChangeReceipt?
            let transportEvidence = TransportEvidence()
            var monitor: Task<Void, Never>?
            do {
                try await publisher.start()
                liveQueue.beginObservedAdmission()
                try emit(["event": "publisher-started"])
                // Telemetry has one independent task. A slow socket observation
                // must not stall the consumer responsible for live sample ingress.
                monitor = Task {
                    do {
                        while !Task.isCancelled {
                            let publishing = await publisher.isPublishing
                            let transport = await publisher.metrics()
                            let statistics = await publisher.transportStatistics()
                            let statisticsSnapshot = transportEvidence.observe(statistics)
                            let observedAt = ProcessInfo.processInfo.systemUptime
                            try emit(["event": "publisher-observation", "publishing": publishing,
                                      "transportStatistics": statisticsEvidence(statistics),
                                      "statisticsObservedAt": observedAt,
                                      "transportWindow": windowEvidence(statisticsSnapshot.freshWindow(at: observedAt)),
                                      "sentBytes": transport.map { $0.2 as Any } ?? NSNull(),
                                      "packetDrops": transport.map { $0.1 as Any } ?? NSNull()])
                            if !publishing { health.fail(); liveQueue.cancel(); return }
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch {
                        if !Task.isCancelled { health.fail(); liveQueue.cancel() }
                    }
                }
                while let sample = try await liveQueue.next() {
                    if !changed && sample.sampleBuffer.presentationTimeStamp.seconds - originSeconds >= 5 {
                        let receipt = try await publisher.setVideoBitRate(configuration.changedBitRate)
                        acceptedReceipt = receipt
                        changed = true
                        try emit(["event": "bitrate-changed", "bitsPerSecond": configuration.changedBitRate,
                                  "receipt": receiptEvidence(receipt)])
                    }
                    if sample.kind == .video {
                        try await publisher.append(sample)
                        publishedVideo += 1
                    } else {
                        try await publisher.append(sample)
                        publishedAudio += sample.sampleBuffer.numSamples
                    }
                }
                guard !health.isFailed else { throw SDKProbe.PublisherError.notPublishing }
                // Production stop owns finalization. No extra harness delay may
                // hide codec or receiver-buffer loss at shutdown.
                let status = await publisher.metrics()
                let transportClockBeforeStop = await publisher.transportClock()
                let publishing = await publisher.isPublishing
                monitor?.cancel()
                await publisher.stop()
                await monitor?.value
                let finalObservations = observations?.close()
                let finalTransport = transportEvidence.close()
                let transportClockAfterStop = await publisher.transportClock()
                let statisticsAfterStop = await publisher.transportStatistics()
                try emit(["event": "publisher-finished", "transportSendEvidence": try sealedTransportEvidence(transportSends), "videoSubmitted": publishedVideo,
                          "audioSamplesSubmitted": publishedAudio, "changedBitrate": changed,
                          "sentBytes": status.map { $0.2 as Any } ?? NSNull(),
                          "packetDrops": status.map { $0.1 as Any } ?? NSNull(),
                          "publishingBeforeStop": publishing,
                          "transportClockBeforeStop": clockEvidence(transportClockBeforeStop),
                          "transportClockAfterStop": clockEvidence(transportClockAfterStop),
                          "transportStatisticsAfterStop": statisticsEvidence(statisticsAfterStop),
                          "encoderEvidence": encoderEvidence.snapshot(),
                          "transportHistory": ["isClosed": finalTransport.isClosed, "isQuarantined": finalTransport.isQuarantined,
                              "samples": finalTransport.samples.map { statisticsEvidence($0) }],
                          "ingressPressure": pressureEvidence(liveQueue.snapshot.ingressObservation),
                          "encoderSourceHistory": sourceEvidence(observations?.sourceHistorySnapshot,
                              clock: transportClockBeforeStop, receipt: acceptedReceipt, aggregate: finalObservations, ingress: liveQueue.snapshot.ingressObservation, transport: finalTransport)])
            } catch {
                liveQueue.cancel()
                monitor?.cancel()
                await publisher.stop()
                await monitor?.value
                // Network failure is reported independently; it cannot cancel the archive.
                try emit(["event": "publisher-failed", "reason": String(describing: error),
                          "firstUnhealthyObservation": health.evidence,
                          "encoderEvidence": encoderEvidence.snapshot(), "transportSendEvidence": try sealedTransportEvidence(transportSends)])
            }
        }
        let started = ContinuousClock.now
        var capturedVideo = 0
        var maximumSourceLag = 0.0
        do {
            while nextVideo != nil || nextAudio != nil {
                try Task.checkCancellation()
                let isVideo = nextAudio == nil || (nextVideo != nil && nextVideo!.presentationTimeStamp <= nextAudio!.presentationTimeStamp)
                let buffer = isVideo ? nextVideo! : nextAudio!
                let elapsed = buffer.presentationTimeStamp.seconds - originSeconds
                try await ContinuousClock().sleep(until: started.advanced(by: .seconds(elapsed)))
                let sample = try CapturedMediaSample(sampleBuffer: buffer, kind: isVideo ? .video : .audio)
                if isVideo { observations?.observe(.captureVideo, sourcePTS: buffer.presentationTimeStamp) }
                guard captureSource.submit(sample), recording.snapshot.failure == nil else { throw Failure.archiveOverflow }
                if url != nil { _ = liveQueue.offer(sample, bytes: sample.retainedByteCount) }
                if isVideo {
                    capturedVideo += 1
                    let wall = started.duration(to: .now).components
                    maximumSourceLag = max(maximumSourceLag, Double(wall.seconds) + Double(wall.attoseconds) / 1e18 - elapsed)
                    if capturedVideo % 30 == 0 {
                        try emit(["event": "capturing", "sourceSeconds": elapsed,
                                  "archiveQueueBytes": recording.snapshot.queue.currentBytes,
                                  "liveQueueBytes": liveQueue.statistics.currentBytes])
                    }
                    nextVideo = try retimed(video.copyNextSampleBuffer(), by: timestampOffset)
                } else { nextAudio = try retimed(audio.copyNextSampleBuffer(), by: timestampOffset) }
            }
            guard reader.status == .completed else { throw Failure.reader }
            liveQueue.finish()
            let recovered = try await recording.stop()
            let status = archive.snapshot
            try emit(["event": "archive-finished", "videoFrames": status.videoFrames,
                      "audioSamples": status.audioSamples, "segments": recovered.segments.count,
                      "archivePeakBytes": recording.snapshot.queue.peakBytes,
                      "livePeakBytes": liveQueue.statistics.peakBytes,
                      "liveDroppedSamples": liveQueue.statistics.droppedCount,
                      "liveRejectedSamples": liveQueue.statistics.rejectedCount,
                      "maximumSourceLagSeconds": maximumSourceLag,
                      "archiveRejected": recording.snapshot.queue.rejectedCount])
            try await publisherTask.value
        } catch {
            captureSource.fail()
            liveQueue.cancel(); publisherTask.cancel()
            _ = try? await recording.stop()
            _ = await publisherTask.result
            throw error
        }
    }
}
