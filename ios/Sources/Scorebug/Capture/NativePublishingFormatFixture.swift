#if DEBUG
import CoreMedia
import Foundation
import ScorebugMedia
import ScorebugStreaming

/// One publishing attempt owns bounded codec and local mux evidence. No sample
/// buffers are retained. Persistence runs only after the adapter joins its stop.
final class NativePublishingFormatFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: VideoFrameObservationScope
    private let profile: PublishingVideoProfile
    let videoCost: PublishingVideoCostOwner
    private var compressedRows: [[String: Any]] = []
    private var encodingRows: [[String: Any]] = []
    private var firstEncoding: [String: Any]?
    private var firstCompressed: [String: Any]?
    private var startupRead: (@Sendable () -> PublishingVideoStartup?)?
    func observeStartup(from publisher: SRTMediaPublisher) {
        lock.withLock { startupRead = { [weak publisher] in publisher?.videoStartup } }
    }
    private var frames = 0
    private var invalid = false
    private var generation: UInt64?
    private var width: Int32?
    private var height: Int32?
    private var first: CMTime?
    private var last: CMTime?
    private var audioRows: [[String: Any]] = []
    private var audioFrames = 0
    private var audioInvalid = false
    private var audioGeneration: UInt64?
    private var lastAudioPTS: CMTime?
    private var muxRows: [String: [[String: Any]]] = ["audio": [], "video": []]
    private var muxFrames = 0
    private var muxInvalid = false
    private var muxGeneration: UInt64?
    init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile) {
        self.scope = scope; self.profile = profile
        videoCost = PublishingVideoCostOwner(scope: scope)
    }
    func recordAudio(generation: UInt64, pts: CMTime, hostTime: UInt64, observedAt: Double,
                     sampleRate: Double, channels: UInt32, framesPerPacket: UInt32,
                     audioObjectType: UInt32, bytes: Int, wasEncoded: Bool, valid: Bool) {
        lock.withLock {
            guard audioFrames < 25_000 else { audioInvalid = true; return }
            audioFrames += 1
            if audioRows.count < 8 {
                audioRows.append(["sourcePTS": Self.time(pts), "hostTime": String(hostTime),
                    "publishingGeneration": String(generation), "observedAt": Self.finite(observedAt),
                    "sampleRate": Self.finite(sampleRate), "channelCount": channels,
                    "framesPerPacket": framesPerPacket, "audioObjectType": audioObjectType,
                    "bytes": bytes, "wasEncoded": wasEncoded, "valid": valid])
            }
            guard valid, wasEncoded, generation > 0, Self.validTime(pts), pts.value >= 0,
                  observedAt.isFinite, observedAt >= 0, sampleRate.isFinite, sampleRate > 0,
                  (1...6).contains(channels) || channels == 8,
                  framesPerPacket == 1024, audioObjectType == 2, (1...8184).contains(bytes) else {
                audioInvalid = true; return
            }
            if let previous = audioGeneration, previous != generation { audioInvalid = true }
            if let previous = lastAudioPTS, CMTimeCompare(pts, previous) <= 0 { audioInvalid = true }
            if audioGeneration == nil { audioGeneration = generation }
            lastAudioPTS = pts
        }
    }
    func observeAudio(_ frame: SRTPublisher.CompressedAudioFrame) {
        recordAudio(generation: frame.publishingGeneration, pts: frame.sourcePTS, hostTime: frame.hostTime,
            observedAt: frame.observedAt, sampleRate: frame.sampleRate, channels: frame.channelCount,
            framesPerPacket: frame.framesPerPacket, audioObjectType: frame.audioObjectType,
            bytes: frame.byteCount, wasEncoded: frame.wasEncoded, valid: frame.valid)
    }
    func recordMux(generation: UInt64, media: String, pts: CMTime, dts: CMTime,
                   transportPTS: UInt64, transportDTS: UInt64?, observedAt: Double) {
        lock.withLock {
            guard muxFrames < 25_000 else { muxInvalid = true; return }
            muxFrames += 1
            guard muxRows[media] != nil else { muxInvalid = true; return }
            if muxRows[media]!.count < 8 {
                muxRows[media]!.append(["sourcePTS": Self.time(pts), "sourceDTS": Self.time(dts),
                    "publishingGeneration": String(generation), "ordinal": muxFrames,
                    "transportPTS": String(transportPTS), "transportDTS": transportDTS.map(String.init) as Any? ?? NSNull(),
                    "observedAt": Self.finite(observedAt)])
            }
            guard generation > 0, Self.validTime(pts), dts == .invalid || Self.validTime(dts),
                  observedAt.isFinite, observedAt >= 0,
                  (9000...UInt64(Int64.max)).contains(transportPTS),
                  dts.isValid == (transportDTS != nil),
                  transportDTS.map({ (9000...UInt64(Int64.max)).contains($0) }) ?? true else {
                muxInvalid = true; return
            }
            if let previous = muxGeneration, previous != generation { muxInvalid = true }
            if muxGeneration == nil { muxGeneration = generation }
        }
    }
    func observeMux(_ frame: SRTPublisher.MuxedPacketFrame) {
        recordMux(generation: frame.publishingGeneration, media: frame.media.rawValue,
            pts: frame.sourcePTS, dts: frame.sourceDTS, transportPTS: frame.transportPTS,
            transportDTS: frame.transportDTS, observedAt: frame.observedAt)
    }
    func observeEncoding(_ frame: SRTPublisher.EncoderFrame) {
        lock.withLock {
            let row: [String: Any] = ["sourcePTS": Self.time(frame.sourcePTS), "outputPTS": Self.time(frame.outputPTS),
                "encoderSessionID": frame.encoderSessionID.uuidString,
                "configurationID": frame.configuration.map { $0.id.uuidString } as Any? ?? NSNull(),
                "configuredBitRate": frame.configuration.map { $0.bitRate } as Any? ?? NSNull(),
                "submittedAt": frame.submittedAt, "completedAt": frame.completedAt]
            firstEncoding = firstEncoding ?? row
            encodingRows.append(row)
            if encodingRows.count > 1024 { encodingRows.removeFirst() }
        }
    }
    func observe(_ frame: SRTPublisher.CompressedVideoFrame) {
        lock.withLock {
            let row: [String: Any] = ["sourcePTS": Self.time(frame.sourcePTS), "publishingGeneration": String(frame.publishingGeneration),
                "width": frame.width, "height": frame.height, "bytes": frame.byteCount,
                "dequeuedAt": frame.dequeuedAt, "valid": frame.valid, "wasEncoded": frame.wasEncoded, "codec": frame.codec,
                "isSync": frame.isSync as Any? ?? NSNull()]
            firstCompressed = firstCompressed ?? row
            compressedRows.append(row)
            if compressedRows.count > 1024 { compressedRows.removeFirst() }
        }
        record(generation: frame.publishingGeneration, pts: frame.sourcePTS, width: frame.width,
               height: frame.height, valid: frame.valid && frame.wasEncoded && frame.codec == kCMVideoCodecType_H264)
    }
    func record(generation: UInt64, pts: CMTime, width: Int32, height: Int32, valid: Bool) {
        lock.withLock {
            guard frames < 25_000 else { invalid = true; return }
            frames += 1
            guard valid, generation > 0, pts.isNumeric, pts.timescale > 0,
                  width > 0, height > 0 else { invalid = true; return }
            if let previous = self.generation, previous != generation { invalid = true }
            if let previous = self.width, previous != width { invalid = true }
            if let previous = self.height, previous != height { invalid = true }
            if let previous = last, previous.epoch != pts.epoch || CMTimeCompare(pts, previous) <= 0 { invalid = true }
            if self.generation == nil { self.generation = generation; self.width = width; self.height = height; first = pts }
            last = pts
        }
    }
    func data() throws -> Data {
        let startup = lock.withLock { startupRead }?()
        let startupJSON: [String: Any]? = startup.map {
            ["profile": $0.profile.rawValue, "width": $0.width, "height": $0.height,
             "publishingGeneration": String($0.publishingGeneration), "encoderSessionID": $0.encoderSessionID.uuidString,
             "firstSourcePTS": Self.time($0.firstSourcePTS), "submittedAt": $0.submittedAt,
             "completedAt": $0.completedAt, "observedAt": $0.observedAt]
        }
        let value: [String: Any] = lock.withLock {
            ["formatVersion": 1, "isClosed": true, "profile": profile.rawValue,
             "startup": startupJSON as Any? ?? NSNull(),
             "firstEncoding": firstEncoding as Any? ?? NSNull(), "firstCompressed": firstCompressed as Any? ?? NSNull(),
             "audioStartup": ["frames": audioFrames, "first": audioRows,
                 "invalid": audioInvalid || (audioGeneration != nil && generation != nil && audioGeneration != generation)],
             "muxStartup": ["frames": muxFrames, "audio": muxRows["audio"]!, "video": muxRows["video"]!,
                 "invalid": muxInvalid || (muxGeneration != nil && generation != nil && muxGeneration != generation)
                    || (muxGeneration != nil && audioGeneration != nil && muxGeneration != audioGeneration)],
             "scope": ["recordingID": scope.recordingID, "matchID": scope.matchID,
                       "broadcastGeneration": scope.broadcastGeneration,
                       "publishingAttemptID": scope.publishingAttemptID.uuidString,
                       "appliedProfileRevision": String(scope.appliedProfileRevision)],
             "frames": frames, "invalid": invalid,
             "publishingGeneration": generation.map { String($0) } as Any? ?? NSNull(),
             "width": width as Any? ?? NSNull(), "height": height as Any? ?? NSNull(),
             "firstSourcePTS": first.map(Self.time) as Any? ?? NSNull(),
             "lastSourcePTS": last.map(Self.time) as Any? ?? NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func costData() throws -> Data {
        let snapshot = videoCost.snapshot
        let rows: [[String: Any]] = snapshot.intervals.map { v in
            ["sequence": String(v.sequence), "publishingGeneration": String(v.publishingGeneration),
             "encoderSessionID": v.encoderSessionID.uuidString,
             "configurationID": v.configuration.map { $0.id.uuidString } as Any? ?? NSNull(),
             "configuredBitRate": v.configuration.map { $0.bitRate } as Any? ?? NSNull(),
             "width": v.width, "height": v.height, "sourceStartExclusive": Self.time(v.sourceStartExclusive),
             "sourceEndInclusive": Self.time(v.sourceEndInclusive), "submissionStart": v.submissionStart,
             "submissionEnd": v.submissionEnd, "observedAt": v.observedAt, "frames": v.frames,
             "maximumFrameBytes": v.maximumFrameBytes, "payloadBytes": String(v.payloadBytes),
             "maximumLatency": v.maximumLatency, "maximumSourceGap": v.maximumSourceGap,
             "sourceDuration": v.sourceDuration, "submissionDuration": v.submissionDuration,
             "payloadBitsPerSecond": v.payloadBitsPerSecond, "usable": v.usable]
        }
        let raw = lock.withLock { (compressedRows, encodingRows) }
        let format = try JSONSerialization.jsonObject(with: data()) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "isClosed": snapshot.isClosed,
            "invalidReason": snapshot.invalidReason as Any? ?? NSNull(), "scope": format["scope"]!,
            "profile": profile.rawValue, "intervals": rows, "compressed": raw.0, "encoded": raw.1], options: [.sortedKeys])
    }
    func persist() {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scorebug/QA", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data().write(to: directory.appendingPathComponent("native-publishing-format.json"), options: .atomic)
            try costData().write(to: directory.appendingPathComponent("native-video-cost.json"), options: .atomic)
        } catch { /* Missing evidence fails qualification; diagnostics never fail recording. */ }
    }
    private static func time(_ value: CMTime) -> [String: Any] {
        ["value": String(value.value), "timescale": value.timescale, "epoch": String(value.epoch), "flags": value.flags.rawValue]
    }
    private static func finite(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
    private static func validTime(_ value: CMTime) -> Bool {
        value.isNumeric && value.timescale > 0 && value.epoch == 0
    }
}
#endif
