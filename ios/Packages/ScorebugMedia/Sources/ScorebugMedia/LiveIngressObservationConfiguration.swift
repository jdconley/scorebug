import Foundation

/// Immutable diagnostics only. Mailbox budgets remain the source of truth for
/// occupancy denominators. Invalid diagnostic configuration disables observations.
public struct LiveIngressObservationConfiguration: Sendable {
    public let scope: VideoFrameObservationScope
    public let monotonicAnchor: Double
    public let windowDuration: Double
    public let completedWindowLimit: Int
    public let initialPhase: LiveIngressPhase

    public init(scope: VideoFrameObservationScope, monotonicAnchor: Double,
                windowDuration: Double = 5, completedWindowLimit: Int = 8,
                initialPhase: LiveIngressPhase = .admitting) {
        self.scope = scope; self.monotonicAnchor = monotonicAnchor
        self.windowDuration = windowDuration; self.completedWindowLimit = completedWindowLimit
        self.initialPhase = initialPhase
    }
}
