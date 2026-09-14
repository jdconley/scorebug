import Foundation

public enum BroadcastCoordinatorError: Error, Equatable, Sendable {
    case busy, pendingCommand, scopeMismatch, storageFailure, invalidServerTime, invalidResponse, notExpired, recordingNotActive, selectionChanged
}

public enum BroadcastCoordinatorStatus: Equatable, Sendable {
    case idle, working, pending, reconciliationRequired, scopeMismatch, storageFailure
}

public struct BroadcastCoordinatorState: Equatable, Sendable {
    public let snapshot: MediaSnapshot?
    public let pending: PendingBroadcastCommand?
    public let outcome: BroadcastOutcome?
    public let status: BroadcastCoordinatorStatus
}

/// One durable broadcast command at a time, independent of the recorder. A
/// stopped local recording must be reported with setActiveRecording(nil); cancel
/// any waiting start/recovery task too. A lost reply remains uncertain until its
/// receipt is found or a fresh server clock proves that command can no longer run.
/// The caller must never turn a recovered historical outcome into local capture.
public actor BroadcastCommandCoordinator {
    private let client: MatchHTTPClient
    private let credential: MatchCredential
    private let installationToken: String
    private let endpointScope: String
    private let store: any PendingBroadcastStore
    private let now: @Sendable () -> Date
    private var snapshot: MediaSnapshot?
    private var pending: PendingBroadcastCommand?
    private var outcome: BroadcastOutcome?
    private var status: BroadcastCoordinatorStatus = .idle
    private var loaded = false
    private var busy = false
    private var activeRecordingId: String?
    private var serverOffset: TimeInterval?

    public init(client: MatchHTTPClient, credential: MatchCredential, installationToken: String,
                endpointScope: String, store: any PendingBroadcastStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.credential = credential; self.installationToken = installationToken
        self.endpointScope = endpointScope; self.store = store; self.now = now
    }

    public func state() -> BroadcastCoordinatorState {
        .init(snapshot: snapshot, pending: pending, outcome: outcome, status: status)
    }

    /// Invalidates an in-flight start before its next network mutation. This
    /// method deliberately remains available while another operation awaits I/O.
    public func setActiveRecording(_ id: String?) { activeRecordingId = id }

    public func refresh() async throws -> BroadcastCoordinatorState {
        try begin(); defer { finish() }
        try loadAndCheckScope()
        _ = try await fetchSnapshot()
        return completedState()
    }

    public func submit(_ operation: BroadcastOperation, activeRecordingId: String?, requiredStopSelection: BroadcastSelection? = nil) async throws -> BroadcastCoordinatorState {
        try begin(); defer { finish() }
        self.activeRecordingId = activeRecordingId
        try loadAndCheckScope()
        guard pending == nil else { throw BroadcastCoordinatorError.pendingCommand }
        try requireActiveRecording(for: operation)
        _ = try await fetchSnapshot()
        try Task.checkCancellation()
        try requireActiveRecording(for: operation)
        guard let snapshot, let serverOffset else { throw BroadcastCoordinatorError.invalidResponse }
        if case .stop = operation, let requiredStopSelection {
            guard snapshot.broadcast.desired == .running,
                  snapshot.broadcast.selection == requiredStopSelection else {
                throw BroadcastCoordinatorError.selectionChanged
            }
        }
        let command = BroadcastCommand(commandId: UUID().uuidString, gameId: credential.gameId,
                                       expectedGeneration: snapshot.broadcast.generation,
                                       issuedAt: Self.format(now().addingTimeInterval(serverOffset)), operation: operation)
        let record = PendingBroadcastCommand(endpointScope: endpointScope, command: command, captureDeviceId: credential.deviceId)
        pending = record
        outcome = nil
        try save(record)
        try acknowledge(try await client.executeBroadcast(command, installationToken: installationToken))
        return completedState()
    }

    /// Receipt-first recovery may replay a start only while that same local
    /// recording is active. A process restart ordinarily supplies nil.
    public func recover(activeRecordingId: String?) async throws -> BroadcastCoordinatorState {
        try begin(); defer { finish() }
        self.activeRecordingId = activeRecordingId
        try loadAndCheckScope()
        guard let pending else { _ = try await fetchSnapshot(); return completedState() }
        if let receipt = try await receipt(pending) {
            try acknowledge(receipt)
            return completedState()
        }
        let serverDate = try await fetchSnapshot()
        guard canRetry(pending, at: serverDate) else {
            status = .reconciliationRequired
            return state()
        }
        try Task.checkCancellation()
        try save(pending)
        try acknowledge(try await client.executeBroadcast(pending.command, installationToken: installationToken))
        return completedState()
    }

    /// A second receipt check after fresh expiration evidence closes the race
    /// where the command committed between the first receipt and snapshot reads.
    public func discardExpired() async throws -> BroadcastCoordinatorState {
        try begin(); defer { finish() }
        try loadAndCheckScope()
        guard let pending else { return completedState() }
        if let receipt = try await receipt(pending) {
            try acknowledge(receipt)
            return completedState()
        }
        let serverDate = try await fetchSnapshot()
        guard let issued = Self.parse(pending.command.issuedAt), serverDate.timeIntervalSince(issued) > 10 else {
            status = .reconciliationRequired
            throw BroadcastCoordinatorError.notExpired
        }
        if let receipt = try await receipt(pending) { try acknowledge(receipt) }
        else { try save(nil); self.pending = nil }
        return completedState()
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw BroadcastCoordinatorError.busy }
        busy = true
        if status == .idle || status == .pending { status = .working }
    }
    private func finish() {
        busy = false
        if status == .working { status = pending == nil ? .idle : .pending }
    }
    private func completedState() -> BroadcastCoordinatorState {
        status = pending == nil ? .idle : .pending
        return state()
    }
    private func loadAndCheckScope() throws {
        if !loaded {
            do {
                let stored = try store.load()
                if let stored, let pending, stored != pending { throw BroadcastCoordinatorError.storageFailure }
                pending = stored ?? pending
                loaded = true
            } catch { status = .storageFailure; throw BroadcastCoordinatorError.storageFailure }
        }
        if let pending {
            guard pending.endpointScope == endpointScope, pending.command.gameId == credential.gameId,
                  pending.captureDeviceId == credential.deviceId else {
                status = .scopeMismatch
                throw BroadcastCoordinatorError.scopeMismatch
            }
        }
    }
    private func save(_ value: PendingBroadcastCommand?) throws {
        do { try store.save(value) }
        catch { loaded = false; status = .storageFailure; throw BroadcastCoordinatorError.storageFailure }
    }
    private func fetchSnapshot() async throws -> Date {
        let response = try await client.mediaSnapshot(credential: credential)
        guard response.snapshot.gameId == credential.gameId else { throw BroadcastCoordinatorError.invalidResponse }
        guard let serverDate = Self.parse(response.serverTime) else { throw BroadcastCoordinatorError.invalidServerTime }
        serverOffset = serverDate.timeIntervalSince(now())
        updateSnapshot(response.snapshot)
        return serverDate
    }
    private func requireActiveRecording(for operation: BroadcastOperation) throws {
        if case let .start(selection) = operation {
            guard credential.role == .capture, selection.captureDeviceId == credential.deviceId,
                  selection.recordingId == activeRecordingId else { throw BroadcastCoordinatorError.recordingNotActive }
        }
    }
    private func canRetry(_ record: PendingBroadcastCommand, at serverDate: Date) -> Bool {
        guard let snapshot, let issued = Self.parse(record.command.issuedAt) else { return false }
        let age = serverDate.timeIntervalSince(issued)
        guard age >= -5, age <= 10, snapshot.broadcast.generation == record.command.expectedGeneration else { return false }
        do { try requireActiveRecording(for: record.command.operation); return true }
        catch { return false }
    }
    private func receipt(_ pending: PendingBroadcastCommand) async throws -> BroadcastOutcome? {
        try await client.broadcastReceipt(gameId: credential.gameId, commandId: pending.command.commandId, installationToken: installationToken)
    }
    private func acknowledge(_ receipt: BroadcastOutcome) throws {
        guard let command = pending?.command, receipt.commandId == command.commandId,
              receipt.snapshot.gameId == credential.gameId,
              receipt.accepted ? receipt.error == nil : receipt.error?.isEmpty == false else {
            throw BroadcastCoordinatorError.invalidResponse
        }
        if receipt.accepted {
            let (generation, overflow) = command.expectedGeneration.addingReportingOverflow(1)
            let broadcast = receipt.snapshot.broadcast
            guard !overflow, broadcast.generation == generation else { throw BroadcastCoordinatorError.invalidResponse }
            switch command.operation {
            case .start(let selection):
                guard broadcast.desired == .running, broadcast.selection == selection else { throw BroadcastCoordinatorError.invalidResponse }
            case .stop:
                guard broadcast.desired == .stopped, broadcast.selection == nil else { throw BroadcastCoordinatorError.invalidResponse }
            }
        }
        try save(nil)
        pending = nil
        outcome = receipt
        updateSnapshot(receipt.snapshot)
    }
    private func updateSnapshot(_ incoming: MediaSnapshot) {
        if snapshot == nil || incoming.broadcast.generation >= snapshot!.broadcast.generation { snapshot = incoming }
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
