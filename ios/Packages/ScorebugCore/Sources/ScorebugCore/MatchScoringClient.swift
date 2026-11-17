import Foundation

/// The scoring operations the outbox (`MatchCommandCoordinator`) needs. Match creation and
/// team-member routes are deliberately outside this interface.
public protocol MatchScoringClient: Sendable {
    func snapshot(credential: MatchCredential) async throws -> MatchSnapshotResponse

    /// Return the authoritative outcome, including domain rejection. A transport
    /// failure leaves the result uncertain and must throw; it is not a rejection.
    func execute(_ command: MatchCommand, credential: MatchCredential) async throws -> CommandOutcome

    /// Nil means the server authoritatively confirmed command absence. Transport,
    /// authentication and malformed-response failures must throw, preserving the
    /// coordinator's pending command for receipt-first recovery.
    func receipt(commandId: String, credential: MatchCredential) async throws -> CommandOutcome?
}
