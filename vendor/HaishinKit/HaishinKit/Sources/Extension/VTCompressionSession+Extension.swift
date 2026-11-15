import Foundation
import VideoToolbox

extension VTCompressionSession {
    func prepareToEncodeFrames() -> OSStatus {
        VTCompressionSessionPrepareToEncodeFrames(self)
    }
}

extension VTCompressionSession: VTSessionConvertible {
    @inline(__always)
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let completion = VideoEncoderCompletion(sourcePTS: sampleBuffer.presentationTimeStamp,
            observer: encoderCompletionObserver, continuation: continuation)
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            self,
            imageBuffer: imageBuffer,
            presentationTimeStamp: completion.sourcePTS,
            duration: sampleBuffer.duration,
            frameProperties: nil,
            infoFlagsOut: &flags,
            outputHandler: { status, flags, sampleBuffer in
                completion.complete(status: status, flags: flags, sampleBuffer: sampleBuffer)
            }
        )
        if status != noErr {
            throw VTSessionError.failedToConvert(status: status)
        }
    }

    func completeFrames() -> OSStatus {
        VTCompressionSessionCompleteFrames(self, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        VTCompressionSessionInvalidate(self)
    }
}

/// One native encode submission owns its timestamp, observer and output queue.
/// No input sample or mutable codec/stream state is retained by the callback.
struct VideoEncoderCompletion: Sendable {
    let sourcePTS: CMTime
    let observer: VideoEncoderCompletionObserver?
    let continuation: PublishingQueue<CMSampleBuffer>?

    func complete(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            continuation?.fail(.codecFailed(status: status == noErr ? -1 : status))
            return
        }
        let outputPTS = sampleBuffer.presentationTimeStamp
        // Data readiness alone includes empty CoreMedia marker buffers.
        // Observation rejection never changes the existing media delivery path.
        if let observer,
           !flags.contains(.frameDropped),
           CMSampleBufferDataIsReady(sampleBuffer),
           CMSampleBufferGetNumSamples(sampleBuffer) == 1,
           let format = sampleBuffer.formatDescription,
           format.mediaType == .video, format.isCompressed,
           let data = sampleBuffer.dataBuffer, data.dataLength > 0,
           sourcePTS.isNumeric, sourcePTS.timescale > 0,
           outputPTS.isNumeric, outputPTS.timescale > 0,
           sourcePTS.epoch == outputPTS.epoch,
           CMTimeCompare(sourcePTS, outputPTS) == 0 {
            observer(sourcePTS, outputPTS)
        }
        continuation?.yield(sampleBuffer, byteCount: sampleBuffer.dataBuffer?.dataLength ?? sampleBuffer.imageBuffer.map { CVPixelBufferGetDataSize($0) } ?? 0)
    }
}
