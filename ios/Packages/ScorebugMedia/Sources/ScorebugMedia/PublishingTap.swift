import CoreMedia
import Foundation

/// Synchronous fan-out from one running recording to the current publishing
/// attempt. Reuse across reconnects, with a fresh tap for each CaptureRecording.
/// A tap retains its attached session, but never starts/stops it. The lifecycle
/// caller must detach and stop the old session when replacing it.
public final class PublishingTap: @unchecked Sendable {
    private let lock = NSLock()
    private var attachment: CapturePublishingAttachment?
    private var closed = false
    public init() {}

    /// Replaces the attachment, including while the publisher is prepared or
    /// starting. False means the recording has closed this tap. Observation owner
    /// closure belongs to the controller after any desired encoder drain.
    @discardableResult public func attach(_ session: PublishingSession,
                                          observations: VideoFrameObservationOwner? = nil) -> Bool {
        var previous: CapturePublishingAttachment?
        let attached = lock.withLock {
            guard !closed else { return false }
            previous = attachment
            previous?.invalidatePublication()
            attachment = CapturePublishingAttachment(session: session, observations: observations)
            return true
        }
        withExtendedLifetime(previous) {}
        return attached
    }
    /// Identity guards old asynchronous teardown from clearing a newer attempt.
    public func detach(_ session: PublishingSession) {
        var previous: CapturePublishingAttachment?
        lock.withLock {
            if attachment?.session === session {
                previous = attachment
                previous?.invalidatePublication()
                attachment = nil
            }
        }
        withExtendedLifetime(previous) {}
    }
    /// Only short bounded mailbox admission occurs here. No disk/network work or
    /// task is created, and publication rejection never fails the archive. Direct
    /// offers are not capture callbacks and do not create capture observations.
    @discardableResult public func offer(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock { attachment?.offer(sample) ?? false }
    }

    /// Resolve one immutable attempt before archive admission. The caller keeps
    /// this attachment through its optional publication offer, never resolving the
    /// tap again for the same callback. Observation rejection is diagnostic only.
    /// A replacement after resolution may leave an observation in the old scope,
    /// but its later publication offer is rejected: boundary loss is never rerouted
    /// to the new attempt. Audio resolves an attachment without observing video.
    func beginCapture(_ sample: CapturedMediaSample) -> CapturePublishingAttachment? {
        let resolved = lock.withLock { attachment }
        if sample.kind == .video {
            resolved?.observations?.observe(.captureVideo, sourcePTS: sample.sampleBuffer.presentationTimeStamp)
        }
        return resolved
    }

    // A recording permanently closes its own tap, including late attachments.
    func close() {
        let previous = lock.withLock {
            closed = true
            let old = attachment
            old?.invalidatePublication()
            attachment = nil
            return old
        }
        withExtendedLifetime(previous) {}
    }
}

/// Immutable attempt identity; only publication admission is mutable, protected
/// by its own lock. Tap mutation takes tap -> attachment lock; publication offer
/// takes attachment -> PublishingSession/mailbox locks. No path reacquires a tap
/// lock from an attachment/session, and observation runs outside these locks.
/// Only bounded synchronous session admission occurs while holding the gate.
///
/// Media is borrowed only during a call. Invalidation never closes observations:
/// the controller owns closure after encoder drain. Tap mutation keeps the previous
/// attachment alive until outside its lock, avoiding PublishingSession deinit and
/// cancellation under that lock.
final class CapturePublishingAttachment: @unchecked Sendable {
    let session: PublishingSession
    let observations: VideoFrameObservationOwner?
    private let lock = NSLock()
    private var acceptsPublication = true
    init(session: PublishingSession, observations: VideoFrameObservationOwner?) {
        self.session = session
        self.observations = observations
    }
    func invalidatePublication() { lock.withLock { acceptsPublication = false } }
    @discardableResult func offer(_ sample: CapturedMediaSample) -> Bool {
        lock.withLock { acceptsPublication && session.offer(sample) }
    }
}
