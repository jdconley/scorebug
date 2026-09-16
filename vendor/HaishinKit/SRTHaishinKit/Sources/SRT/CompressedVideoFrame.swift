import CoreMedia
import Foundation

extension SRTStream {
    /// Bounded scalar view of the actual pre-mux compressed sample. The synchronous
    /// observer must not retain media or perform I/O. This is not receiver evidence.
    public struct CompressedVideoFrame: Sendable {
        public let publishingGeneration: UInt64
        public let sourcePTS: CMTime
        public let width: Int32
        public let height: Int32
        public let codec: FourCharCode
        public let valid: Bool
        public let wasEncoded: Bool
        /// Consumer dequeue uptime, before optional pacing. Not encoder completion.
        public let sourceCadencePaced: Bool
        public let dequeuedAt: Double
        public let byteCount: Int
        /// CoreMedia sync metadata, not a bitstream parse or receiver-delivery proof.
        /// Invalid samples have no sync evidence. An absent NotSync key means sync.
        public let isSync: Bool?
        init(sampleBuffer: CMSampleBuffer, generation: UInt64, wasEncoded: Bool,
             dequeuedAt: Double = ProcessInfo.processInfo.systemUptime, sourceCadencePaced: Bool = false) {
            self.sourceCadencePaced = sourceCadencePaced
            self.dequeuedAt = dequeuedAt
            publishingGeneration = generation; sourcePTS = sampleBuffer.presentationTimeStamp
            self.wasEncoded = wasEncoded
            let format = sampleBuffer.formatDescription
            let isVideo = format.map { CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video } ?? false
            let dimensions = isVideo ? CMVideoFormatDescriptionGetDimensions(format!) : CMVideoDimensions(width: 0, height: 0)
            width = dimensions.width; height = dimensions.height
            codec = format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            byteCount = CMSampleBufferGetTotalSampleSize(sampleBuffer)
            valid = isVideo && sampleBuffer.imageBuffer == nil && CMSampleBufferDataIsReady(sampleBuffer) &&
                CMSampleBufferGetNumSamples(sampleBuffer) == 1 && byteCount > 0 &&
                sourcePTS.isNumeric && sourcePTS.timescale > 0 && width > 0 && height > 0
            if valid {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
                let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String]
                if let notSync {
                    isSync = (notSync as? Bool).map { !$0 }
                } else {
                    isSync = true
                }
            } else {
                isSync = nil
            }
        }
    }
}
