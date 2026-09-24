import CoreMedia
import Foundation

/// Native verified configuration at submission, not achieved per-frame bitrate.
public struct VideoEncoderConfiguration: Equatable, Sendable {
    public let id: UUID
    public let encoderSessionID: UUID
    public let bitRate: Int
}

/// Historical scalar evidence from a qualifying native compression completion.
public struct VideoEncoderFrame: Sendable {
    public let sourcePTS: CMTime
    public let outputPTS: CMTime
    public let encoderSessionID: UUID
    public let configuration: VideoEncoderConfiguration?
    public let submittedAt: Double
    public let completedAt: Double
}

public typealias VideoEncoderConfigurationObserver = @Sendable (VideoEncoderFrame) -> Void

/// Accepted write boundary. A later matching frame proves a submission used this
/// configuration; convergence of the average rate still needs media measurement.
public struct VideoBitRateChange: Sendable {
    public let settings: VideoCodecSettings
    public let configuration: VideoEncoderConfiguration
    public let acceptedAt: Double
    public let lastSubmittedSourcePTS: CMTime?
}


/// Synchronous compression submission wrapper, separate from output completion.
/// Scalar diagnostics only; a successful return does not prove encoded delivery.
public struct VideoEncoderSubmission: Sendable {
    public let sourcePTS: CMTime
    public let encoderSessionID: UUID
    public let startedAt: Double
    public let returnedAt: Double
    public let status: Int32
}

/// Must remain bounded and synchronous; never wait, perform I/O or create tasks.
public typealias VideoEncoderSubmissionObserver = @Sendable (VideoEncoderSubmission) -> Void
