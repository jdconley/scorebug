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
    /// Cached selection queried once after preparing this encoder session.
    /// Not a fresh per-frame measurement, utilization, or throughput guarantee.
    public let selectionQueriedAfterPreparation: VideoEncoderHardwareSelection?
}

/// Observational only. Unavailable evidence is never inferred to mean software.
public enum VideoEncoderHardwareSelection: Equatable, Sendable {
    case hardware, software
    case readFailed(status: Int32)
    case missingValue, invalidType, notQueriedOnPlatform

    static func read(from session: any VTSessionConvertible) -> Self {
        #if os(macOS)
        let result = session.copyOption(.usingHardwareAcceleratedVideoEncoder)
        guard result.status == noErr else { return .readFailed(status: result.status) }
        guard let value = result.value else { return .missingValue }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return .invalidType }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? .hardware : .software
        #else
        return .notQueriedOnPlatform
        #endif
    }
}

/// Must remain bounded and synchronous; never wait, perform I/O or create tasks.
public typealias VideoEncoderSubmissionObserver = @Sendable (VideoEncoderSubmission) -> Void

/// A value selector, never authority to mutate an encoder. The owner compares its
/// retained actual receipt and notification revision again at native admission.
public struct VideoBitRateExpectation: Sendable {
    public let configurationID: UUID
    public let encoderSessionID: UUID
    public let bitRate: Int
    public let acceptedAt: Double
    public let lastSubmittedSourcePTS: CMTime?

    public init(configurationID: UUID, encoderSessionID: UUID, bitRate: Int,
                acceptedAt: Double, lastSubmittedSourcePTS: CMTime?) {
        self.configurationID = configurationID; self.encoderSessionID = encoderSessionID
        self.bitRate = bitRate; self.acceptedAt = acceptedAt
        self.lastSubmittedSourcePTS = lastSubmittedSourcePTS
    }
    public init(_ change: VideoBitRateChange) {
        self.init(configurationID: change.configuration.id, encoderSessionID: change.configuration.encoderSessionID,
                  bitRate: change.configuration.bitRate, acceptedAt: change.acceptedAt,
                  lastSubmittedSourcePTS: change.lastSubmittedSourcePTS)
    }
    package func matches(_ change: VideoBitRateChange?) -> Bool {
        guard let change else { return false }
        return configurationID == change.configuration.id && encoderSessionID == change.configuration.encoderSessionID
            && bitRate == change.configuration.bitRate && acceptedAt.bitPattern == change.acceptedAt.bitPattern
            && exactVideoSourceTime(lastSubmittedSourcePTS, change.lastSubmittedSourcePTS)
    }
}

/// The current call made no encoder mutation. Post-write/drain uncertainty never
/// uses this result, even if the notification revision is now obsolete.
public enum VideoMutationAdmissionError: Error, Equatable, Sendable { case stale }

package func exactVideoSourceTime(_ lhs: CMTime?, _ rhs: CMTime?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?):
        return lhs.value == rhs.value && lhs.timescale == rhs.timescale && lhs.flags == rhs.flags && lhs.epoch == rhs.epoch
    default: return false
    }
}

/// Private package ownership minted only by a committed replacement's first
/// successful submission. Public selectors cannot manufacture this identity.
package struct VideoReplacementContinuation: Sendable {
    package let id: UUID
    package let previousEncoderSessionID: UUID
    package let encoderSessionID: UUID
    package let firstSourcePTS: CMTime
}
