import Foundation

/// Typed scoring over one owned companion request/reply transport. The injected
/// sender owns reachability, finite deadlines and request lifetime. This client
/// neither retries mutations nor switches routes; uncertain outcomes remain for
/// the coordinator's durable receipt-first recovery.
public struct WatchRelayScoringClient: MatchScoringClient {
    public typealias Sender = @Sendable (Data) async throws -> Data
    private let scope: WatchRelayScope
    private let requestId: @Sendable () -> String
    private let send: Sender

    public init(scope: WatchRelayScope, requestId: @escaping @Sendable () -> String = { UUID().uuidString },
                send: @escaping Sender) {
        self.scope = scope; self.requestId = requestId; self.send = send
    }

    public func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse {
        guard case .snapshot(let response) = try await perform(.snapshot, credential: credential) else {
            throw MatchClientError.invalidResponse
        }
        return response
    }

    public func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome {
        guard case .outcome(let outcome) = try await perform(.execute(command), credential: credential) else {
            throw MatchClientError.invalidResponse
        }
        return outcome
    }

    public func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome? {
        switch try await perform(.receipt(commandId: commandId), credential: credential) {
        case .receiptFound(let outcome): return outcome
        case .receiptAbsent: return nil
        default: throw MatchClientError.invalidResponse
        }
    }

    private func perform(_ operation: WatchRelayOperation, credential: MatchCredential) async throws -> WatchRelayResult {
        try Task.checkCancellation()
        let request = WatchRelayRequest(requestId: requestId(), scope: scope, credential: credential, operation: operation)
        let encoded = try WatchRelayCodec.encodeRequest(request)
        try Task.checkCancellation()
        let data = try await send(encoded)
        // A sent operation may have committed even after cancellation. Never
        // turn a late reply into an acknowledgment for the canceled operation.
        try Task.checkCancellation()
        let reply = try WatchRelayCodec.decodeReply(data, for: request)
        try Task.checkCancellation()
        if case .failure(let failure) = reply.result {
            switch failure {
            case .unauthorized: throw MatchClientError.unauthorized
            case .forbidden: throw MatchClientError.forbidden
            case .http(let status, let code): throw MatchClientError.http(status: status, code: code)
            case .invalidResponse: throw MatchClientError.invalidResponse
            default: throw failure
            }
        }
        return reply.result
    }
}
