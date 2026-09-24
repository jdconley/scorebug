import AVFoundation
import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import HaishinKit

@Suite(.serialized) struct VideoCodecBitRateTests {
    private final class Session: VTSessionConvertible {
        var options: [String: AnyObject] = [:]
        var writes = 0, conversions = 0, invalidations = 0
        var onWrite: (() -> Void)?
        var onConvert: (() -> Void)?
        var writeStatus: OSStatus = noErr
        var convertStatus: OSStatus = noErr
        var convertEnteredAt = 0.0, convertReturnedAt = 0.0
        var hardwareReads = 0
        var hardwareStatus: OSStatus = noErr
        var hardwareValue: CFTypeRef? = kCFBooleanTrue
        var onHardwareRead: (() -> Void)?
        func setOption(_ option: VTSessionOption) -> OSStatus {
            writes += 1; options[option.key.rawValue] = option.value; onWrite?()
            return writeStatus
        }
        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { noErr }
        func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) {
            #if os(macOS)
            if key == .usingHardwareAcceleratedVideoEncoder {
                hardwareReads += 1; onHardwareRead?()
                return (hardwareStatus, hardwareValue)
            }
            #endif
            return (noErr, options[key.rawValue])
        }
        func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
            conversions += 1
            onConvert?()
            convertEnteredAt = ProcessInfo.processInfo.systemUptime
            defer { convertReturnedAt = ProcessInfo.processInfo.systemUptime }
            if convertStatus != noErr { throw VTSessionError.failedToConvert(status: convertStatus) }
        }
        func completeFrames() -> OSStatus { noErr }
        func invalidate() { invalidations += 1 }
    }
    #if os(macOS)
    @Test func hardwareSelectionUsesExactNativeBooleanAndPreservesUnavailableOutcomes() throws {
        let cases: [(OSStatus, CFTypeRef?, VideoEncoderHardwareSelection)] = [
            (noErr, kCFBooleanTrue, .hardware), (noErr, kCFBooleanFalse, .software),
            (noErr, NSNumber(value: true), .hardware),
            (noErr, NSNumber(value: 1), .invalidType), (noErr, NSNumber(value: 0), .invalidType),
            (noErr, "true" as CFString, .invalidType), (noErr, nil, .missingValue),
            (-123, nil, .readFailed(status: -123)), (-456, kCFBooleanTrue, .readFailed(status: -456)),
        ]
        for (status, value, expected) in cases {
            let session = Session(), observations = SubmissionCallRows()
            session.hardwareStatus = status; session.hardwareValue = value
            let codec = VideoCodec(encoderSubmissionObserver: observations.record, sessionFactory: { _, _ in session })
            _ = codec.outputStream; codec.startRunning()
            codec.append(try frame(0)); codec.append(try frame(1))
            #expect(session.hardwareReads == 1)
            #expect(observations.rows.count == 2)
            #expect(observations.rows.allSatisfy { $0.selectionQueriedAfterPreparation == expected })
            #expect(codec.failure.error == nil && session.conversions == 2)
            codec.stopRunning()
        }
    }
    @Test func selectionRetainsSessionOwnershipAcrossBitrateReplacementAndLateSubmission() throws {
        let first = Session(), second = Session(), rows = SubmissionCallRows()
        second.hardwareValue = kCFBooleanFalse
        var creations = 0
        let codec = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in
            creations += 1; return creations == 1 ? first : second
        })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        let firstID = try #require(rows.rows.first?.encoderSessionID)
        _ = try codec.setVerifiedBitRate(3_000_000)
        codec.append(try frame(1))
        #expect(first.hardwareReads == 1)
        let pending = try #require(codec.prepareSubmission(frame(2)))
        codec.requestSessionInvalidation()
        #expect(pending.run())
        #expect(!codec.commitSubmission(pending, succeeded: true))
        codec.append(try frame(3))
        #expect(first.hardwareReads == 1 && second.hardwareReads == 1)
        #expect(rows.rows.prefix(3).allSatisfy { $0.encoderSessionID == firstID && $0.selectionQueriedAfterPreparation == .hardware })
        #expect(rows.rows.last?.encoderSessionID != firstID)
        #expect(rows.rows.last?.selectionQueriedAfterPreparation == .software)
        codec.stopRunning(); codec.startRunning(); _ = codec.outputStream
        codec.append(try frame(0))
        #expect(second.hardwareReads == 2)
        #expect(rows.rows.last?.encoderSessionID != rows.rows[3].encoderSessionID)
        codec.stopRunning()
    }
    @Test func selectionInvalidatedDuringReadCannotBeSubmittedOrLeakToNewSession() throws {
        let first = Session(), second = Session(), rows = SubmissionCallRows()
        second.hardwareValue = kCFBooleanFalse
        var creations = 0
        let codec = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in
            creations += 1; return creations == 1 ? first : second
        })
        first.onHardwareRead = { codec.requestSessionInvalidation() }
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        #expect(first.hardwareReads == 1 && first.conversions == 0 && rows.rows.isEmpty)
        codec.append(try frame(1))
        #expect(first.invalidations == 1 && second.hardwareReads == 1)
        #expect(rows.rows.count == 1 && rows.rows[0].selectionQueriedAfterPreparation == .software)
        codec.stopRunning()
    }
    @Test func explicitReplacementQueriesItsOwnPreparedSession() throws {
        let first = Session(), second = Session(), rows = SubmissionCallRows()
        second.hardwareStatus = -123
        var creations = 0
        let codec = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in
            creations += 1; return creations == 1 ? first : second
        })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        let previous = try #require(rows.rows.first)
        let replacement = try codec.prepareReplacement(.default)
        replacement.drain(); try codec.commitReplacement(replacement)
        codec.append(try frame(1)); codec.append(try frame(2))
        #expect(first.hardwareReads == 1 && second.hardwareReads == 1)
        #expect(rows.rows[1].encoderSessionID != previous.encoderSessionID)
        #expect(rows.rows.suffix(2).allSatisfy { $0.selectionQueriedAfterPreparation == .readFailed(status: -123) })
        #expect(codec.failure.error == nil)
        codec.stopRunning()
    }
    @Test func stopDuringSelectionReadCannotResurrectPreparedSession() throws {
        let session = Session(), rows = SubmissionCallRows()
        let codec = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in session })
        session.onHardwareRead = { codec.stopRunning() }
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        #expect(session.hardwareReads == 1 && session.conversions == 0)
        #expect(rows.rows.isEmpty && !codec.isRunning)
        #expect(codec.session == nil)
    }
    #endif
    @Test func noSelectionQueryWithoutObserverOrForDecompression() throws {
        let session = Session(), codec = try ready(session)
        codec.append(try frame(1)); codec.stopRunning()
        #expect(session.hardwareReads == 0)
        let other = Session(), rows = SubmissionCallRows()
        let decoder = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in other })
        _ = decoder.outputStream; decoder.startRunning(); decoder.append(try compressedFrame())
        #expect(other.hardwareReads == 0 && rows.rows.isEmpty)
        decoder.stopRunning()
    }
    #if !os(macOS)
    @Test func platformOmissionDoesNotQueryOrPreventSubmission() throws {
        let session = Session(), rows = SubmissionCallRows()
        let codec = VideoCodec(encoderSubmissionObserver: rows.record, sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        #expect(session.hardwareReads == 0)
        #expect(rows.rows.first?.selectionQueriedAfterPreparation == .notQueriedOnPlatform)
        codec.stopRunning()
    }
    #endif
    @Test(arguments: [Int32(0), Int32(-1234)])
    func submissionCallObserverBracketsReturnAndPreservesFailure(status: Int32) throws {
        let session = Session(), observations = SubmissionCallRows()
        session.convertStatus = status
        let codec = VideoCodec(encoderSubmissionObserver: observations.record, sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning()
        let input = try frame(0)
        codec.append(input)
        let row = try #require(observations.rows.first)
        #expect(observations.rows.count == 1)
        #expect(row.sourcePTS == input.presentationTimeStamp)
        #expect(row.startedAt.isFinite && row.startedAt <= session.convertEnteredAt)
        #expect(row.returnedAt.isFinite && row.returnedAt >= session.convertReturnedAt)
        #expect(row.status == status)
        #expect(codec.failure.error == (status == 0 ? nil : .codecFailed(status: status)))
        if status == 0 { #expect(row.encoderSessionID == codec.lastSubmission?.sessionID) }
        codec.stopRunning()
    }

    @Test func invalidationDuringSubmissionRevokesCommitAndRebuildsAfterReturn() throws {
        let first = Session(), second = Session()
        var creations = 0
        let codec = VideoCodec(sessionFactory: { _, _ in creations += 1; return creations == 1 ? first : second })
        _ = codec.outputStream; codec.startRunning()
        let operation = try #require(codec.prepareSubmission(frame(0)))
        first.onConvert = {
            codec.requestSessionInvalidation()
            #expect(first.invalidations == 0, "Notification must not destroy a session inside its native call")
            #expect(codec.lastSubmission == nil)
        }
        let succeeded = operation.run()
        #expect(succeeded)
        #expect(!codec.commitSubmission(operation, succeeded: succeeded))
        #expect(codec.lastSubmission == nil && first.invalidations == 0)
        first.onConvert = nil
        let fresh = try #require(codec.prepareSubmission(frame(1)))
        #expect(first.invalidations == 1 && creations == 2)
        #expect(fresh.revision != operation.revision)
        #expect(codec.commitSubmission(fresh, succeeded: fresh.run()))
        #expect(!codec.commitSubmission(operation, succeeded: true))
        #expect(!codec.commitSubmission(fresh, succeeded: true))
        #expect(codec.lastSubmission?.sourcePTS == CMTime(value: 1, timescale: 30))
        #expect(codec.lastSubmission?.sessionID == fresh.revision)
        codec.stopRunning()
    }

    @Test func compressedConversionDoesNotReportCompressionSubmission() throws {
        let session = Session(), observations = SubmissionCallRows()
        let codec = VideoCodec(encoderSubmissionObserver: observations.record, sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning(); codec.append(try compressedFrame())
        #expect(session.conversions == 1)
        #expect(observations.rows.isEmpty)
        codec.stopRunning()
    }

    private func ready(_ session: Session) throws -> VideoCodec {
        let codec = VideoCodec(sessionFactory: { _, _ in session })
        _ = codec.outputStream
        codec.startRunning(); codec.append(try frame(0))
        return codec
    }

    @Test func missingOrStoppedEncoderNeverReceivesAnUpdate() throws {
        let session = Session()
        let codec = VideoCodec(sessionFactory: { _, _ in session })
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try codec.setVerifiedBitRate(3_000_000) }
        codec.startRunning()
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try codec.setVerifiedBitRate(3_000_000) }
        _ = codec.outputStream; codec.append(try frame(0)); codec.stopRunning()
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try codec.setVerifiedBitRate(3_000_000) }
        #expect(session.writes == 0)
    }

    @Test func verifiedUpdateCommitsOnceAndKeepsEncoding() throws {
        let session = Session(), codec = try ready(session)
        let updated = try codec.setVerifiedBitRate(3_000_000)
        #expect(updated.bitRate == 3_000_000)
        #expect(codec.settings.bitRate == 3_000_000)
        #expect(session.writes == 2, "Committing settings must not repeat unchecked writes")
        _ = try codec.setVerifiedBitRate(3_000_000)
        #expect(session.writes == 4, "Unchanged requests still verify native settings")
        codec.append(try frame(1)); #expect(session.conversions == 2)
        codec.stopRunning()
    }

    @Test func pendingInvalidationRejectsWithoutMutationAndNextInputRebuilds() throws {
        let first = Session(), second = Session()
        var creations = 0
        let codec = VideoCodec(sessionFactory: { _, _ in creations += 1; return creations == 1 ? first : second })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        codec.requestSessionInvalidation()
        #expect(throws: VideoBitRateUpdateError.sessionInvalidated) { try codec.setVerifiedBitRate(3_000_000) }
        #expect(first.writes == 0); #expect(codec.failure.error == nil)
        codec.append(try frame(1))
        _ = try codec.setVerifiedBitRate(3_000_000)
        #expect(creations == 2); #expect(first.invalidations == 1); #expect(second.writes == 2)
        codec.stopRunning()
    }

    @Test func invalidationDuringCreationIsNotLost() throws {
        let first = Session(), second = Session()
        var creations = 0
        let codec = VideoCodec(sessionFactory: { _, codec in
            creations += 1
            if creations == 1 { codec.requestSessionInvalidation(); return first }
            return second
        })
        _ = codec.outputStream; codec.startRunning(); codec.append(try frame(0))
        #expect(first.conversions == 0)
        #expect(throws: VideoBitRateUpdateError.sessionInvalidated) { try codec.setVerifiedBitRate(3_000_000) }
        codec.append(try frame(1))
        #expect(creations == 2); #expect(second.conversions == 1)
        _ = try codec.setVerifiedBitRate(3_000_000)
        codec.stopRunning()
    }

    @Test func invalidationDuringWriteIsTerminalAndCannotCommit() throws {
        let session = Session(), codec = try ready(session)
        let previous = codec.settings.bitRate
        session.onWrite = { codec.requestSessionInvalidation() }
        #expect(throws: VideoBitRateUpdateError.sessionInvalidated) { try codec.setVerifiedBitRate(3_000_000) }
        #expect(codec.settings.bitRate == previous); #expect(codec.failure.error != nil)
        #expect(codec.lastBitRateChange == nil)
        session.onWrite = nil; codec.stopRunning()
    }

    @Test func asynchronousFailureDuringWriteCannotCommit() throws {
        let session = Session(), codec = try ready(session)
        let previous = codec.settings.bitRate
        session.onWrite = { codec.failure.fail(.codecFailed(status: -88)) }
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try codec.setVerifiedBitRate(3_000_000) }
        #expect(codec.settings.bitRate == previous)
        #expect(codec.failure.error == .codecFailed(status: -88))
        #expect(codec.lastBitRateChange == nil)
        session.onWrite = nil; codec.stopRunning()
    }

    @Test func nativeWriteFailureLatchesOnlyLiveCodecFailure() throws {
        let session = Session(), codec = try ready(session)
        let previous = codec.settings.bitRate
        session.writeStatus = -77
        #expect(throws: VideoBitRateUpdateError.writeFailed(property: "AverageBitRate", status: -77)) {
            try codec.setVerifiedBitRate(3_000_000)
        }
        #expect(codec.failure.error == .codecFailed(status: -77))
        #expect(codec.settings.bitRate == previous)
        codec.stopRunning()
    }

    @Test func preflightFailureDoesNotTerminateEncoder() throws {
        let session = Session(), codec = try ready(session)
        #expect(throws: VideoBitRateUpdateError.invalidBitRate) { try codec.setVerifiedBitRate(0) }
        #expect(session.writes == 0); #expect(codec.failure.error == nil)
        codec.append(try frame(1)); #expect(session.conversions == 2)
        codec.stopRunning()
    }

    @Test func decompressionSessionCannotAcknowledgeEncoderSettings() throws {
        let session = Session()
        let codec = VideoCodec(sessionFactory: { _, _ in session })
        _ = codec.outputStream; codec.startRunning(); codec.append(try compressedFrame())
        #expect(session.conversions == 1)
        #expect(throws: VideoBitRateUpdateError.notEncoding) { try codec.setVerifiedBitRate(3_000_000) }
        #expect(session.writes == 0); codec.stopRunning()
    }

    private func frame(_ index: Int) throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let buffer = try #require(image)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func compressedFrame() throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 64, height: 64, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 4,
            flags: 0, blockBufferOut: &block) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4, sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: try #require(format), sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}

private final class SubmissionCallRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VideoEncoderSubmission] = []
    var rows: [VideoEncoderSubmission] { lock.withLock { stored } }
    func record(_ value: VideoEncoderSubmission) { lock.withLock { stored.append(value) } }
}
