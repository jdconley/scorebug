import CoreMedia
import Foundation
import HaishinKit
import ScorebugMedia

/// A finite proposed-profile measurement, scoped to the live state that requested it.
public final class PublishingCandidateEncoder: Sendable {
    public struct Result: Sendable {
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        /// Optional actual A/V mux cost, never spare uplink capacity.
        public let transport: PublishingCandidateTransport.Result?
        /// Actual pre-mux video output, including the initial keyframe.
        public let encoding: VideoCandidateEncoder.Result
        init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
             encoding: VideoCandidateEncoder.Result, transport: PublishingCandidateTransport.Result? = nil) {
            self.scope = scope; self.profile = profile; self.encoding = encoding; self.transport = transport
        }
    }

    public let id: UUID
    public let scope: VideoFrameObservationScope
    public let profile: PublishingVideoProfile
    public let requestedSettings: VideoCodecSettings
    private let encoder: VideoCandidateEncoder
    private let transport: PublishingCandidateTransport?

    public init(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
                transport: PublishingCandidateTransport? = nil) throws {
        let candidateID = UUID()
        if let transport {
            guard transport.scope == scope, transport.profile == profile, transport.bind(id: candidateID) else {
                throw CandidateTransportError.identity
            }
        }
        let consumer: (@Sendable (CMSampleBuffer) -> Bool)?
        if let transport { consumer = { transport.observeVideo($0) } } else { consumer = nil }
        let encoder: VideoCandidateEncoder
        do {
            encoder = try VideoCandidateEncoder(settings: profile.settings, id: candidateID,
                compressedOutputConsumer: consumer)
        } catch { transport?.cancel(); throw error }
        self.encoder = encoder; self.transport = transport
        id = encoder.id
        self.scope = scope
        self.profile = profile
        requestedSettings = encoder.settings
    }

    public func start() async throws {
        do { try await encoder.start() } catch { transport?.cancel(); throw error }
    }

    /// The caller retains ownership of capture and must not mutate admitted media.
    /// False means this sample was not accepted; inspect the joined result.
    @discardableResult
    public func offer(_ sample: CMSampleBuffer) -> Bool {
        if let transport, !transport.advanceRaw(sample.presentationTimeStamp) { transport.cancel(); return false }
        // advanceRaw has released the window lock before SDK admission.
        let accepted = encoder.offer(sample)
        if !accepted { transport?.cancel() }
        return accepted
    }

    public func finish() async -> Result {
        await withTaskCancellationHandler {
            transport?.closeRawWindow()
            let encoded = await encoder.finish()
            if encoded.outcome != .completed { transport?.cancel() }
            let measured = await transport?.finish()
            return .init(scope: scope, profile: profile, encoding: encoded, transport: measured)
        } onCancel: {
            // Revoke AAC immediately, even while native completion remains
            // blocked. The operation still joins both native and window owners.
            transport?.cancel()
        }
    }

    public func cancel() async -> Result {
        transport?.cancel()
        let encoded = await encoder.cancel()
        let measured = await transport?.finish()
        return .init(scope: scope, profile: profile, encoding: encoded, transport: measured)
    }
}

private enum CandidateTransportError: Error { case identity }
