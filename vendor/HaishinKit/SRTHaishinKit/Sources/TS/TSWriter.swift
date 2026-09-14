import AVFoundation
import CoreMedia
import Foundation
import HaishinKit

/// An object that represents writes MPEG-2 transport stream data.
final class TSWriter {
    static let defaultPATPID: UInt16 = 0
    static let defaultPMTPID: UInt16 = 4095
    static let defaultVideoPID: UInt16 = 256
    static let defaultAudioPID: UInt16 = 257
    static let defaultSegmentDuration: Double = 2
    /// An asynchronous sequence for writing data.
    public var output: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    /// Specifies the exptected medias = [.video, .audio].
    var expectedMedias: Set<AVMediaType> = []
    /// Specifies the audio format.
    var audioFormat: AVAudioFormat? {
        didSet {
            guard let audioFormat, audioFormat != oldValue else {
                return
            }
            var data = ESSpecificData()
            data.streamType = audioFormat.formatDescription.streamType
            data.elementaryPID = Self.defaultAudioPID
            pmt.elementaryStreamSpecificData.removeAll { $0.elementaryPID == data.elementaryPID }
            pmt.elementaryStreamSpecificData.append(data)
            audioContinuityCounter = 0
            writeProgramIfNeeded()
        }
    }
    /// Specifies the video format.
    var videoFormat: CMFormatDescription? {
        didSet {
            guard let videoFormat, videoFormat != oldValue else {
                return
            }
            var data = ESSpecificData()
            data.streamType = videoFormat.streamType
            data.elementaryPID = Self.defaultVideoPID
            pmt.elementaryStreamSpecificData.removeAll { $0.elementaryPID == data.elementaryPID }
            pmt.elementaryStreamSpecificData.append(data)
            videoContinuityCounter = 0
            writeProgramIfNeeded()
        }
    }

    private(set) var pat: TSProgramAssociation = {
        let PAT: TSProgramAssociation = .init()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        return PAT
    }()
    private(set) var pmt: TSProgramMap = .init()
    private var pcrPID: UInt16 = TSWriter.defaultVideoPID
    private var canWriteFor: Bool {
        guard !expectedMedias.isEmpty else {
            return true
        }
        if expectedMedias.contains(.audio) && expectedMedias.contains(.video) {
            return audioFormat != nil && videoFormat != nil
        }
        if expectedMedias.contains(.video) {
            return videoFormat != nil
        }
        if expectedMedias.contains(.audio) {
            return audioFormat != nil
        }
        return false
    }
    // PES data owns copied compressed bytes; codec buffers may be reused after append.
    private struct PendingPacket {
        var pes: PacketizedElementaryStream
        let media: AVMediaType
        let presentationTime: CMTime
        let decodeTime: CMTime
        let randomAccess: Bool
        var time: CMTime { decodeTime.isValid ? decodeTime : presentationTime }
    }

    struct StartupLimits {
        var packetCount = 256
        var byteCount = 8 * 1024 * 1024
        var mediaSpan: Double = 2
    }

    private(set) var error: SRTStream.MuxerError?
    private let startupLimits: StartupLimits
    private var pending: [PendingPacket] = []
    private var pendingBytes = 0
    private var initialMedias: Set<AVMediaType> = []
    private var startupMinimum: CMTime = .invalid
    private var startupMaximum: CMTime = .invalid
    private var origin: CMTime = .invalid
    private var clockTimeStamp: CMTime = .zero
    private var segmentDuration: Double = TSWriter.defaultSegmentDuration
    private var rotatedTimeStamp: CMTime = .zero
    private var audioContinuityCounter: UInt8 = 0
    private var videoContinuityCounter: UInt8 = 0
    private var continuation: AsyncStream<Data>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    /// Creates a new instance with segument duration.
    init(segmentDuration: Double = 2.0, startupLimits: StartupLimits = .init()) {
        self.segmentDuration = segmentDuration
        self.startupLimits = startupLimits
    }

    /// Appends audio, retaining startup payloads until each required track arrives.
    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard error == nil, let audioBuffer = audioBuffer as? AVAudioCompressedBuffer else { return }
        guard when.isHostTimeValid else { fail(.invalidTimestamp); return }
        let timestamp = when.makeTime()
        guard valid(timestamp) else { fail(.invalidTimestamp); return }
        guard preflightTimes(timestamp, decodeTime: .invalid) else { return }
        guard audioBuffer.byteLength > 0, audioBuffer.byteLength <= audioBuffer.byteCapacity,
              audioBuffer.packetCount > 0,
              AudioSpecificConfig(formatDescription: audioBuffer.format.formatDescription) != nil else { fail(.invalidPayload); return }
        guard preflightPayload(Int(audioBuffer.byteLength)) else { return }
        guard let pes = PacketizedElementaryStream(audioBuffer, when: when, timeStamp: timestamp) else {
            fail(.invalidPayload)
            return
        }
        append(PendingPacket(pes: pes, media: .audio, presentationTime: timestamp,
            decodeTime: .invalid, randomAccess: true))
    }

    /// Appends a compressed video buffer.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard error == nil, sampleBuffer.formatDescription?.mediaType == .video else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let dts = sampleBuffer.decodeTimeStamp
        guard valid(pts), dts == .invalid || valid(dts) else { fail(.invalidTimestamp); return }
        guard preflightTimes(pts, decodeTime: dts) else { return }
        guard let block = sampleBuffer.dataBuffer, block.dataLength > 0 else { fail(.invalidPayload); return }
        let parameterBytes = sampleBuffer.formatDescription?.parameterSets.reduce(0) { $0 + $1.count + 4 } ?? 0
        guard preflightPayload(block.dataLength + parameterBytes + 6) else { return }
        guard let pes = PacketizedElementaryStream(sampleBuffer, timeStamp: min(pts, dts.isValid ? dts : pts)),
              !pes.data.isEmpty else {
            fail(.invalidPayload)
            return
        }
        append(PendingPacket(pes: pes, media: .video, presentationTime: pts,
            decodeTime: dts, randomAccess: !sampleBuffer.isNotSync))
    }

    private func valid(_ time: CMTime) -> Bool {
        time.isNumeric && time.epoch == 0 && time.seconds.isFinite
    }

    // Bound timestamp arithmetic before the PES initializer converts seconds to Int64.
    private func preflightTimes(_ pts: CMTime, decodeTime: CMTime) -> Bool {
        let time = decodeTime.isValid ? decodeTime : pts
        if origin.isValid {
            let maximumSeconds = Double(Int64.max) / TSTimestamp.resolution - 1
            guard time >= origin, pts >= origin,
                  (pts - origin).seconds < maximumSeconds,
                  (time - origin).seconds < maximumSeconds else {
                fail(.invalidTimestamp)
                return false
            }
        } else {
            let low = startupMinimum.isValid ? min(startupMinimum, min(pts, time)) : min(pts, time)
            let high = startupMaximum.isValid ? max(startupMaximum, max(pts, time)) : max(pts, time)
            guard (high - low).seconds <= startupLimits.mediaSpan else {
                fail(.startupTimeLimitExceeded)
                return false
            }
        }
        return true
    }

    // Reject oversized input before allocating a compressed payload copy.
    private func preflightPayload(_ bytes: Int) -> Bool {
        guard !origin.isValid else { return true }
        guard pending.count < startupLimits.packetCount else { fail(.startupPacketLimitExceeded); return false }
        guard bytes <= startupLimits.byteCount - pendingBytes else { fail(.startupByteLimitExceeded); return false }
        return true
    }

    private func append(_ packet: PendingPacket) {
        if origin.isValid {
            emit(packet)
            return
        }
        let minimum = min(packet.presentationTime, packet.time)
        let maximum = max(packet.presentationTime, packet.time)
        let low = startupMinimum.isValid ? min(startupMinimum, minimum) : minimum
        let high = startupMaximum.isValid ? max(startupMaximum, maximum) : maximum
        guard (high - low).seconds <= startupLimits.mediaSpan else { fail(.startupTimeLimitExceeded); return }
        // Account for the owned PES payload and header, including ADTS/SPS/PPS bytes.
        let bytes = packet.pes.data.count + 6 + (packet.pes.optionalPESHeader?.data.count ?? 0)
        guard preflightPayload(bytes) else { return }
        startupMinimum = low
        startupMaximum = high
        pendingBytes += bytes
        pending.append(packet)
        initialMedias.insert(packet.media)
        guard canWriteFor, expectedMedias.isSubset(of: initialMedias) else { return }
        origin = low
        clockTimeStamp = origin
        rotatedTimeStamp = origin
        pcrPID = initialMedias.contains(.video) ? Self.defaultVideoPID : Self.defaultAudioPID
        writeProgram()
        let startup = pending
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        for packet in startup { emit(packet) }
    }

    private func emit(_ packet: PendingPacket) {
        guard error == nil else { return }
        guard packet.time >= origin, packet.presentationTime >= origin,
              (packet.presentationTime - origin).seconds < Double(Int64.max) / TSTimestamp.resolution,
              (packet.time - origin).seconds < Double(Int64.max) / TSTimestamp.resolution else {
            fail(.invalidTimestamp)
            return
        }
        var pes = packet.pes
        pes.optionalPESHeader = PESOptionalHeader()
        pes.optionalPESHeader?.dataAlignmentIndicator = true
        // Upstream adds the transport lead to PTS only. Apply the same lead to DTS
        // so rebasing preserves the encoder's PTS minus DTS composition offset.
        let decodeTime = packet.decodeTime.isValid ? packet.decodeTime + PESOptionalHeader.offset : .invalid
        pes.optionalPESHeader?.setTimestamp(origin, presentationTimeStamp: packet.presentationTime,
            decodeTimeStamp: decodeTime)
        pes.streamID = packet.media == .audio ? 192 : 224
        writePacketizedElementaryStream(packet.media == .audio ? Self.defaultAudioPID : Self.defaultVideoPID,
            PES: pes, timeStamp: packet.time, randomAccessIndicator: packet.randomAccess)
    }

    private func fail(_ failure: SRTStream.MuxerError) {
        guard error == nil else { return }
        error = failure
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        continuation?.finish()
    }

    /// Clears the writer object for new transport stream.
    func clear() {
        audioFormat = nil
        audioContinuityCounter = 0
        videoFormat = nil
        videoContinuityCounter = 0
        pcrPID = Self.defaultVideoPID
        pat.programs.removeAll()
        pat.programs = [1: Self.defaultPMTPID]
        pmt = TSProgramMap()
        origin = .invalid
        startupMinimum = .invalid
        startupMaximum = .invalid
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        initialMedias.removeAll()
        error = nil
        clockTimeStamp = .zero
        rotatedTimeStamp = .zero
        expectedMedias.removeAll()
        continuation = nil
    }

    private func writePacketizedElementaryStream(_ PID: UInt16, PES: PacketizedElementaryStream, timeStamp: CMTime, randomAccessIndicator: Bool) {
        let packets: [TSPacket] = split(PID, PES: PES, timestamp: timeStamp)
        rotateFileHandle(timeStamp)

        packets[0].adaptationField?.randomAccessIndicator = randomAccessIndicator

        var bytes = Data()
        for var packet in packets {
            switch PID {
            case Self.defaultAudioPID:
                packet.continuityCounter = audioContinuityCounter
                audioContinuityCounter = (audioContinuityCounter + 1) & 0x0f
            case Self.defaultVideoPID:
                packet.continuityCounter = videoContinuityCounter
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0f
            default:
                break
            }
            bytes.append(packet.data)
        }

        write(bytes)
    }

    private func rotateFileHandle(_ timestamp: CMTime) {
        let duration = timestamp.seconds - rotatedTimeStamp.seconds
        guard segmentDuration < duration else {
            return
        }
        writeProgramIfNeeded()
        rotatedTimeStamp = timestamp
    }

    private func write(_ data: Data) {
        guard error == nil else { return }
        continuation?.yield(data)
    }

    private func writeProgram() {
        pmt.PCRPID = pcrPID
        var bytes = Data()
        var packets: [TSPacket] = []
        packets.append(contentsOf: pat.arrayOfPackets(Self.defaultPATPID))
        packets.append(contentsOf: pmt.arrayOfPackets(Self.defaultPMTPID))
        for packet in packets {
            bytes.append(packet.data)
        }
        write(bytes)
    }

    private func writeProgramIfNeeded() {
        guard !expectedMedias.isEmpty else {
            return
        }
        guard canWriteFor, origin.isValid, error == nil else {
            return
        }
        writeProgram()
    }

    private func split(_ PID: UInt16, PES: PacketizedElementaryStream, timestamp: CMTime) -> [TSPacket] {
        var PCR: UInt64?
        let duration: Double = timestamp.seconds - clockTimeStamp.seconds
        if pcrPID == PID && 0.02 <= duration {
            PCR = UInt64((timestamp - origin).seconds * TSTimestamp.resolution)
            clockTimeStamp = timestamp
        }
        var packets: [TSPacket] = []
        for packet in PES.arrayOfPackets(PID, PCR: PCR) {
            packets.append(packet)
        }
        return packets
    }
}
