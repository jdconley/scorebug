import Foundation
import ScorebugCore

/// Revocable authority for one currently attached worker delivery context.
/// Immutable identity plus locked revocation allows queued actor work to check
/// retirement synchronously. Sample freshness is checked separately.
final class PublishingDeliveryAuthority: @unchecked Sendable {
    private let context: WorkerDecoderDeliveryFreshness.Context
    private let scopeID: String
    private let lock = NSLock()
    private var revoked = false
    init(delivery: WorkerDecoderDeliveryFreshness) {
        context = delivery.context; scopeID = delivery.snapshot.scopeID
    }
    func permits(_ delivery: WorkerDecoderDeliveryFreshness) -> Bool {
        lock.withLock { !revoked && context == delivery.context && scopeID == delivery.snapshot.scopeID }
    }
    func revoke() { lock.withLock { revoked = true } }
}
