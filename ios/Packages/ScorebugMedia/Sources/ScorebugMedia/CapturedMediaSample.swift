@preconcurrency import AVFoundation

/// An immutable, strongly retained view of a capture callback's ready media.
/// No copy is made: producers and consumers must not mutate/invalidate the sample,
/// its image/block buffers, or attachments after wrapping it. ARC retains these
/// objects until all branches release the wrapper. This contract permits Sendable.
public struct CapturedMediaSample: @unchecked Sendable {
    public enum Kind: Sendable { case video, audio }
    public enum SampleError: Error { case invalidMedia }
    public let sampleBuffer: CMSampleBuffer
    public let kind: Kind
    /// Retained payload estimate: pixel allocation (including row padding) plus
    /// block-buffer data. Excludes CoreMedia metadata, encoder allocations, and
    /// externally shared parent/pool allocations; it is not a process RSS limit.
    public let retainedByteCount: Int

    public init(sampleBuffer: CMSampleBuffer, kind: Kind) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer), let format = sampleBuffer.formatDescription,
              CMFormatDescriptionGetMediaType(format) == (kind == .video ? kCMMediaType_Video : kCMMediaType_Audio)
        else { throw SampleError.invalidMedia }
        var bytes = sampleBuffer.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0
        if let pixel = sampleBuffer.imageBuffer {
            guard kind == .video else { throw SampleError.invalidMedia }
            let planes = CVPixelBufferGetPlaneCount(pixel)
            let rows = planes == 0
                ? CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)
                : (0..<planes).reduce(0) { $0 + CVPixelBufferGetBytesPerRowOfPlane(pixel, $1) * CVPixelBufferGetHeightOfPlane(pixel, $1) }
            let (total, overflow) = bytes.addingReportingOverflow(max(CVPixelBufferGetDataSize(pixel), rows))
            guard !overflow else { throw SampleError.invalidMedia }
            bytes = total
        }
        guard bytes > 0 else { throw SampleError.invalidMedia }
        self.sampleBuffer = sampleBuffer
        self.kind = kind
        retainedByteCount = bytes
    }
}
