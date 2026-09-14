import Foundation
import VideoToolbox

extension VTCompressionSession {
    func prepareToEncodeFrames() -> OSStatus {
        VTCompressionSessionPrepareToEncodeFrames(self)
    }
}

extension VTCompressionSession: VTSessionConvertible {
    @inline(__always)
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?) throws {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            self,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: nil,
            infoFlagsOut: &flags,
            outputHandler: { status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else {
                    continuation?.fail(.codecFailed(status: status == noErr ? -1 : status))
                    return
                }
                do {
                    continuation?.yield(sampleBuffer, byteCount: sampleBuffer.dataBuffer?.dataLength ?? sampleBuffer.imageBuffer.map { CVPixelBufferGetDataSize($0) } ?? 0)
                }
            }
        )
        if status != noErr {
            throw VTSessionError.failedToConvert(status: status)
        }
    }

    func invalidate() {
        VTCompressionSessionInvalidate(self)
    }
}
