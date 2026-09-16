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
        outputQueue?.finish()
        outputAccounting = TransportOutputAccounting()
        let queue = PublishingQueue<Data>(boundary: "transport muxer", limits: outputLimits, failure: failure)
        outputQueue = queue
        return queue.stream
    }
    var failure = PublishingFailureLatch()
    private var outputQueue: PublishingQueue<Data>?
    /// Stream-actor accounting; excludes the payload held by its sole consumer.
    private(set) var outputAccounting = TransportOutputAccounting()
    var pendingOutputCount: Int { outputAccounting.pending }
    func didDequeueOutput() {
        guard outputAccounting.dequeue() else { fail(.invalidPayload); return }
    }
    private let outputLimits: PublishingQueue<Data>.Limits
    private let maximumPayloadBytes: Int
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
    private(set) var transportClock: TransportClock?
    private var origin: CMTime { transportClock?.origin ?? .invalid }
    private var lastPCRTicks: UInt64 = 0
    private var segmentDuration: Double = TSWriter.defaultSegmentDuration
    private var rotatedClockTicks: UInt64 = 0
    private var audioContinuityCounter: UInt8 = 0
    private var videoContinuityCounter: UInt8 = 0
    /// Creates a new instance with segument duration.
    init(segmentDuration: Double = 2.0, startupLimits: StartupLimits = .init(),
         outputLimits: PublishingQueue<Data>.Limits = .init(count: 32, bytesPerItem: 2 * 1024 * 1024 + 64 * 1024),
         maximumPayloadBytes: Int = 2 * 1024 * 1024) {
        self.outputLimits = outputLimits
        self.maximumPayloadBytes = maximumPayloadBytes
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
        // ADTS has a 13-bit frame length including its seven-byte header.
        guard audioBuffer.byteLength <= 8191 - 7 else { fail(.payloadByteLimitExceeded); return }
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

    // Validate the exact projection before PES initializers allocate payloads.
    private func preflightTimes(_ pts: CMTime, decodeTime: CMTime) -> Bool {
        let time = decodeTime.isValid ? decodeTime : pts
        if transportClock == nil {
            let low = startupMinimum.isValid ? min(startupMinimum, min(pts, time)) : min(pts, time)
            let high = startupMaximum.isValid ? max(startupMaximum, max(pts, time)) : max(pts, time)
            guard (high - low).seconds <= startupLimits.mediaSpan else {
                fail(.startupTimeLimitExceeded)
                return false
            }
        }
        guard let clock = transportClock ?? TransportClock(origin: min(pts, time)),
              clock.presentationTimestamp(for: pts) != nil,
              clock.presentationTimestamp(for: time) != nil else {
            fail(.invalidTimestamp)
            return false
        }
        return true
    }

    // Reject oversized input before allocating a compressed payload copy.
    private func preflightPayload(_ bytes: Int) -> Bool {
        guard bytes <= maximumPayloadBytes else { fail(.payloadByteLimitExceeded); return false }
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
        guard let clock = TransportClock(origin: low), pending.allSatisfy({
            clock.presentationTimestamp(for: $0.presentationTime) != nil &&
            clock.presentationTimestamp(for: $0.time) != nil
        }) else { fail(.invalidTimestamp); return }
        transportClock = clock
        lastPCRTicks = 0
        rotatedClockTicks = 0
        pcrPID = initialMedias.contains(.video) ? Self.defaultVideoPID : Self.defaultAudioPID
        writeProgram()
        let startup = pending
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        for packet in startup { emit(packet) }
    }

    private func emit(_ packet: PendingPacket) {
        guard error == nil else { return }
        var header = PESOptionalHeader()
        header.dataAlignmentIndicator = true
        guard let clock = transportClock,
              let ticks = clock.clockReference(for: packet.time),
              header.setTimestamp(clock.origin, presentationTimeStamp: packet.presentationTime,
                                  decodeTimeStamp: packet.decodeTime) else {
            fail(.invalidTimestamp)
            return
        }
        var pes = packet.pes
        pes.optionalPESHeader = header
        pes.streamID = packet.media == .audio ? 192 : 224
        writePacketizedElementaryStream(packet.media == .audio ? Self.defaultAudioPID : Self.defaultVideoPID,
            PES: pes, clockTicks: ticks, randomAccessIndicator: packet.randomAccess)
    }

    private func fail(_ failure: SRTStream.MuxerError) {
        guard error == nil else { return }
        error = failure
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        outputQueue?.finish()
        self.failure.fail(.muxerFailed(reason: String(describing: failure)))
    }

    /// End transport output after both compressed input consumers have drained.
    /// Retain muxer state until the transport consumer accepts its final payload.
    func finishOutput() {
        // Accepted PES cannot disappear just because another expected track
        // never arrived before stop. No valid common-origin stream was emitted.
        guard pending.isEmpty else { fail(.incompleteStartup); return }
        outputQueue?.finish()
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
        transportClock = nil
        startupMinimum = .invalid
        startupMaximum = .invalid
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        initialMedias.removeAll()
        error = nil
        lastPCRTicks = 0
        rotatedClockTicks = 0
        expectedMedias.removeAll()
        outputQueue?.finish()
        outputQueue = nil
        outputAccounting = TransportOutputAccounting()
        failure.finish()
        failure = PublishingFailureLatch()
    }

    private func writePacketizedElementaryStream(_ PID: UInt16, PES: PacketizedElementaryStream, clockTicks: UInt64, randomAccessIndicator: Bool) {
        let packets: [TSPacket] = split(PID, PES: PES, clockTicks: clockTicks)
        rotateFileHandle(clockTicks)

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

    private func rotateFileHandle(_ ticks: UInt64) {
        guard ticks >= rotatedClockTicks,
              segmentDuration < Double(ticks - rotatedClockTicks) / Double(TransportClock.timescale) else {
            return
        }
        writeProgramIfNeeded()
        rotatedClockTicks = ticks
    }

    private func write(_ data: Data) {
        guard error == nil else { return }
        if let outputQueue {
            if !outputAccounting.enqueue({ outputQueue.yield(data, byteCount: data.count) }) {
                fail(data.count > outputLimits.bytesPerItem ? .outputByteLimitExceeded : .outputQueueLimitExceeded)
            }
        }
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

    private func split(_ PID: UInt16, PES: PacketizedElementaryStream, clockTicks: UInt64) -> [TSPacket] {
        var PCR: UInt64?
        if pcrPID == PID, clockTicks >= lastPCRTicks, clockTicks - lastPCRTicks >= 1_800 {
            PCR = clockTicks
            lastPCRTicks = clockTicks
        }
        var packets: [TSPacket] = []
        for packet in PES.arrayOfPackets(PID, PCR: PCR) {
            packets.append(packet)
        }
        return packets
    }
}
