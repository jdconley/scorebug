@preconcurrency import AVFoundation

/// Constant, non-sensitive capture failures. Any loss makes the archive incomplete.
public enum CaptureSourceEvent: Sendable { case droppedSample, interrupted, failed }

public struct CaptureSourceCallbacks: Sendable {
    public let sample: @Sendable (CapturedMediaSample) -> Void
    public let event: @Sendable (CaptureSourceEvent) -> Void

    public init(sample: @escaping @Sendable (CapturedMediaSample) -> Void,
                event: @escaping @Sendable (CaptureSourceEvent) -> Void) {
        self.sample = sample; self.event = event
    }
}

/// One-use offline capture source. The owner serializes prepare/start/stop calls;
/// implementations isolate device configuration and blocking work off MainActor.
/// Keep callbacks/delegates strongly owned until stop. Deliver immutable samples
/// synchronously without unbounded dispatch, queues, or tasks per sample.
public protocol CaptureSource: Sendable {
    /// Configure capture and return a numeric origin in the SAME clock/timeline as
    /// both audio and video presentation timestamps. Capture may run to establish
    /// that clock, but sample delivery stays disabled until start. Failure events
    /// must still be delivered during preparation. Request permissions here only
    /// in response to the caller's explicit recording action.
    func prepare(callbacks: CaptureSourceCallbacks) async throws -> CMTime

    /// Enable delivery after the recording sink is ready at the returned origin.
    func start() async throws

    /// Detach and quiesce ALL callbacks before returning, including in-flight
    /// sample/error callbacks. Stop underlying capture. Must work after partial
    /// preparation or failed start, and return only once teardown is complete.
    /// Report teardown failure through event(.failed) before quiescing callbacks.
    func stop() async
}
