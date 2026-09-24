import AVFoundation
import Foundation

/// One retained native call. Only immutable inputs cross the actor boundary;
/// the caller runs this once and joins it before changing or invalidating session.
package final class VideoSubmission: @unchecked Sendable {
    package let revision: UUID
    let sample: CMSampleBuffer
    let session: any VTSessionConvertible
    let output: PublishingQueue<CMSampleBuffer>
    let failure: PublishingFailureLatch
    let configuration: VideoEncoderConfiguration?
    let completionObserver: VideoEncoderCompletionObserver?
    let configurationObserver: VideoEncoderConfigurationObserver?
    let submissionObserver: VideoEncoderSubmissionObserver?

    init(revision: UUID, sample: CMSampleBuffer, session: any VTSessionConvertible,
         output: PublishingQueue<CMSampleBuffer>, failure: PublishingFailureLatch,
         configuration: VideoEncoderConfiguration?, completionObserver: VideoEncoderCompletionObserver?,
         configurationObserver: VideoEncoderConfigurationObserver?, submissionObserver: VideoEncoderSubmissionObserver?) {
        self.revision = revision; self.sample = sample; self.session = session
        self.output = output; self.failure = failure; self.configuration = configuration
        self.completionObserver = completionObserver; self.configurationObserver = configurationObserver
        self.submissionObserver = submissionObserver
    }

    package func run() -> Bool {
        guard failure.error == nil else { return false }
        let startedAt = configurationObserver != nil || submissionObserver != nil
            ? ProcessInfo.processInfo.systemUptime : 0
        let completion: VideoEncoderCompletionObserver?
        if let configurationObserver {
            let legacy = completionObserver, revision = revision, configuration = configuration
            completion = { source, output in
                let completedAt = ProcessInfo.processInfo.systemUptime
                legacy?(source, output)
                configurationObserver(.init(sourcePTS: source, outputPTS: output,
                    encoderSessionID: revision, configuration: configuration,
                    submittedAt: startedAt, completedAt: completedAt))
            }
        } else { completion = completionObserver }
        var status: OSStatus = noErr
        defer {
            submissionObserver?(.init(sourcePTS: sample.presentationTimeStamp, encoderSessionID: revision,
                startedAt: startedAt, returnedAt: ProcessInfo.processInfo.systemUptime, status: status))
        }
        do {
            try session.convert(sample, continuation: output, encoderCompletionObserver: completion)
            return true
        } catch {
            status = (error as? VTSessionError)?.status ?? -1
            failure.fail(.codecFailed(status: status))
            logger.warn(error)
            return false
        }
    }
}
