import CoreMedia
import Foundation
import HaishinKit
import ScorebugMedia

/// A finite proposed-profile measurement, scoped to the live state that requested it.
public final class PublishingCandidateEncoder: Sendable {
    public struct Result: Sendable {
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        /// Actual pre-mux video output, including the initial keyframe. Neither
        /// requested bitrate nor these bytes establish spare uplink capacity.
        public let encoding: VideoCandidateEncoder.Result
    }

    public let id: UUID
    public let scope: VideoFrameObservationScope
    public let profile: PublishingVideoProfile
    public let requestedSettings: VideoCodecSettings
    private let encoder: VideoCandidateEncoder

    public init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile) throws {
        let encoder = try VideoCandidateEncoder(settings: profile.settings)
        self.encoder = encoder
        id = encoder.id
        self.scope = scope
        self.profile = profile
        requestedSettings = encoder.settings
    }

    public func start() async throws { try await encoder.start() }

    /// The caller retains ownership of capture and must not mutate admitted media.
    /// False means this sample was not accepted; inspect the joined result.
    @discardableResult
    public func offer(_ sample: CMSampleBuffer) -> Bool { encoder.offer(sample) }

    public func finish() async -> Result {
        .init(scope: scope, profile: profile, encoding: await encoder.finish())
    }

    public func cancel() async -> Result {
        .init(scope: scope, profile: profile, encoding: await encoder.cancel())
    }
}
