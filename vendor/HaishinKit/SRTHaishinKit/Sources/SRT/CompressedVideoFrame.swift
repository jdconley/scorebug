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
        init(sampleBuffer: CMSampleBuffer, generation: UInt64, wasEncoded: Bool) {
            publishingGeneration = generation; sourcePTS = sampleBuffer.presentationTimeStamp
            self.wasEncoded = wasEncoded
            let format = sampleBuffer.formatDescription
            let isVideo = format.map { CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video } ?? false
            let dimensions = isVideo ? CMVideoFormatDescriptionGetDimensions(format!) : CMVideoDimensions(width: 0, height: 0)
            width = dimensions.width; height = dimensions.height
            codec = format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            valid = isVideo && sampleBuffer.imageBuffer == nil && CMSampleBufferDataIsReady(sampleBuffer) &&
                CMSampleBufferGetNumSamples(sampleBuffer) == 1 && CMSampleBufferGetTotalSampleSize(sampleBuffer) > 0 &&
                sourcePTS.isNumeric && sourcePTS.timescale > 0 && width > 0 && height > 0
        }
    }
}
