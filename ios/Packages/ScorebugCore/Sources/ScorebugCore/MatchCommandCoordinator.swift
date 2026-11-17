import Foundation

public enum MatchCoordinatorError: Error, Equatable, Sendable {
    case busy
    case pendingCommand
    case scopeMismatch
    case storageFailure
    case invalidServerTime
    case invalidResponse
    case notExpired
    case scoringNotAllowed
}

public enum MatchCoordinatorStatus: Equatable, Sendable {
    case idle, working, pending, reconciliationRequired, scopeMismatch, storageFailure
}

public struct MatchCoordinatorState: Equatable, Sendable {
    public let snapshot: MatchSnapshot?
    public let pending: PendingMatchCommand?
    public let outcome: CommandOutcome?
    public let status: MatchCoordinatorStatus
}

/// Durable, single-command scoring outbox. Give each outbox file one active
/// coordinator owner. Endpoint/account changes require a
/// new coordinator and scope; an old pending record then blocks all network use.
public actor MatchCommandCoordinator {
    private let client: any MatchScoringClient
    private let credential: MatchCredential
    private let endpointScope: String
    private let store: any PendingCommandStore
    private let now: @Sendable () -> Date
    private var snapshot: MatchSnapshot?
    private var pending: PendingMatchCommand?
    private var outcome: CommandOutcome?
    private var status: MatchCoordinatorStatus = .idle
    private var loaded = false
    private var busy = false
    private var serverOffset: TimeInterval?

    public init(client: any MatchScoringClient, credential: MatchCredential, endpointScope: String,
                store: any PendingCommandStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.credential = credential
        self.endpointScope = endpointScope
        self.store = store
        self.now = now
    }

    public func state() -> MatchCoordinatorState {
        MatchCoordinatorState(snapshot: snapshot, pending: pending, outcome: outcome, status: status)
    }

    /// Updates the view and clock without replaying a pending command.
    public func refresh() async throws -> MatchCoordinatorState {
        try begin()
        defer { finish() }
        try loadAndCheckScope()
        _ = try await fetchSnapshot()
        return completedState()
    }

    /// Always queries the original receipt before considering a retry. A missing
    /// receipt is replayable only with a fresh, matching server context and age.
    public func recover() async throws -> MatchCoordinatorState {
        try begin()
        defer { finish() }
        try loadAndCheckScope()
        guard let pending else {
            _ = try await fetchSnapshot()
            return completedState()
        }
        if let receipt = try await client.receipt(commandId: pending.command.commandId, credential: credential) {
            try acknowledge(receipt)
            return completedState()
        }
        let serverDate = try await fetchSnapshot()
        guard canRetry(pending, serverDate: serverDate) else {
            status = .reconciliationRequired
            return state()
        }
        // A preceding write may have failed before installing the file. Never
        // resend an in-memory recovery record without durable persistence.
        try save(pending)
        try acknowledge(try await client.execute(pending.command, credential: credential))
        return completedState()
    }

    /// Persists the generated UUID and complete command before the first send.
    /// Transport failures preserve that exact record for receipt-first recovery.
    public func submit(_ operation: MatchOperation) async throws -> MatchCoordinatorState {
        try begin()
        defer { finish() }
        try loadAndCheckScope()
        guard pending == nil else { throw MatchCoordinatorError.pendingCommand }
        if snapshot == nil || serverOffset == nil { _ = try await fetchSnapshot() }
        guard let snapshot, let serverOffset else { throw MatchCoordinatorError.invalidResponse }
        guard credential.role == .score, snapshot.status == .active,
              operation == .takeOver || snapshot.scorer.deviceId == credential.deviceId else {
            throw MatchCoordinatorError.scoringNotAllowed
        }
        let command = MatchCommand(commandId: UUID().uuidString, gameId: credential.gameId,
                                   deviceId: credential.deviceId, expectedRevision: snapshot.revision,
                                   scorerEpoch: snapshot.scorer.epoch,
                                   issuedAt: Self.format(now().addingTimeInterval(serverOffset)), operation: operation)
        let record = PendingMatchCommand(endpointScope: endpointScope, command: command,
                                         originalScorerDeviceId: snapshot.scorer.deviceId)
        // Keep the attempted record in memory on storage failure so recovery
        // checks its receipt and persists it successfully before any resend.
        pending = record
        outcome = nil
        try save(record)
        try acknowledge(try await client.execute(command, credential: credential))
        return completedState()
    }

    /// Explicit reconciliation: clear only a known durable outcome, or an absent
    /// receipt proven expired by fresh server time. Query again AFTER that time
    /// to catch a command committed between the first receipt and snapshot reads.
    public func discardExpired() async throws -> MatchCoordinatorState {
        try begin()
        defer { finish() }
        try loadAndCheckScope()
        guard let pending else { return completedState() }
        if let receipt = try await client.receipt(commandId: pending.command.commandId, credential: credential) {
            try acknowledge(receipt)
            return completedState()
        }
        let serverDate = try await fetchSnapshot()
        guard let issuedAt = Self.parse(pending.command.issuedAt),
              serverDate.timeIntervalSince(issuedAt) > 10 else {
            status = .reconciliationRequired
            throw MatchCoordinatorError.notExpired
        }
        if let receipt = try await client.receipt(commandId: pending.command.commandId, credential: credential) {
            try acknowledge(receipt)
        } else {
            try save(nil)
            self.pending = nil
        }
        return completedState()
    }

    private func begin() throws {
        guard !busy else { throw MatchCoordinatorError.busy }
        busy = true
        // Preserve reconciliation/failure status until a successful operation.
        if status == .idle || status == .pending { status = .working }
    }

    private func finish() {
        busy = false
        if status == .working { status = pending == nil ? .idle : .pending }
    }

    private func completedState() -> MatchCoordinatorState {
        status = pending == nil ? .idle : .pending
        return state()
    }

    private func loadAndCheckScope() throws {
        if !loaded {
            do {
                let stored = try store.load()
                if let stored, let pending, stored != pending { throw MatchCoordinatorError.storageFailure }
                // A failed initial save can leave nil on disk. Preserve that
                // in-memory attempt for receipt-first recovery before resending.
                pending = stored ?? pending
                loaded = true
            } catch { status = .storageFailure; throw MatchCoordinatorError.storageFailure }
        }
        guard let pending else { return }
        guard pending.endpointScope == endpointScope,
              pending.command.gameId == credential.gameId,
              pending.command.deviceId == credential.deviceId else {
            status = .scopeMismatch
            throw MatchCoordinatorError.scopeMismatch
        }
    }

    private func save(_ record: PendingMatchCommand?) throws {
        do { try store.save(record) }
        catch {
            // Next operation must reload the unchanged committed disk value
            // before deciding whether a command can be recovered or resent.
            loaded = false
            status = .storageFailure
            throw MatchCoordinatorError.storageFailure
        }
    }

    @discardableResult
    private func fetchSnapshot() async throws -> Date {
        let envelope = try await client.snapshot(credential: credential)
        guard envelope.snapshot.id == credential.gameId else { throw MatchCoordinatorError.invalidResponse }
        guard let serverDate = Self.parse(envelope.serverTime) else { throw MatchCoordinatorError.invalidServerTime }
        serverOffset = serverDate.timeIntervalSince(now())
        updateSnapshot(envelope.snapshot)
        return serverDate
    }

    private func canRetry(_ record: PendingMatchCommand, serverDate: Date) -> Bool {
        guard let snapshot, let issuedAt = Self.parse(record.command.issuedAt) else { return false }
        let age = serverDate.timeIntervalSince(issuedAt)
        return age >= -5 && age <= 10 && snapshot.status == .active
            && snapshot.revision == record.command.expectedRevision
            && snapshot.scorer.epoch == record.command.scorerEpoch
            && snapshot.scorer.deviceId == record.originalScorerDeviceId
    }

    private func acknowledge(_ receipt: CommandOutcome) throws {
        guard receipt.commandId == pending?.command.commandId,
              receipt.snapshot.id == credential.gameId else { throw MatchCoordinatorError.invalidResponse }
        // No acknowledgement reaches the UI until the outbox clear succeeds.
        try save(nil)
        pending = nil
        outcome = receipt
        updateSnapshot(receipt.snapshot)
    }

    private func updateSnapshot(_ incoming: MatchSnapshot) {
        if snapshot == nil || incoming.revision >= snapshot!.revision { snapshot = incoming }
    }

    private static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
