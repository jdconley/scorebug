import Foundation
import ScorebugCore
import SwiftUI

struct PhoneWatchConnection: Codable, Equatable, Sendable {
    let label: String
    let endpoint: String
    let installationToken: String
}
struct PhoneWatchRequest: Codable, Equatable, Sendable {
    var version = 1
    let connection: PhoneWatchConnection
    let gameId: String
    let request: WatchPairingIssueRequest
    var offer: WatchPairingIssued?
}
/// One atomic Keychain value. Confirmation replaces pending setup secrets with a
/// nonsecret relay association. A distinct offer can await Watch acceptance while
/// the previous confirmed association remains usable.
struct PhoneWatchSetupRecord: Codable, Equatable, Sendable {
    let pending: PhoneWatchRequest?
    let relayBinding: WatchRelayScope?
    let requiresNewRequest: Bool
    init(pending: PhoneWatchRequest? = nil, relayBinding: WatchRelayScope? = nil,
         requiresNewRequest: Bool = false) {
        self.pending = pending; self.relayBinding = relayBinding; self.requiresNewRequest = requiresNewRequest
    }
    private enum Keys: String, CodingKey { case version, pending, relayBinding, requiresNewRequest }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Int.self, forKey: .version) {
        case 1:
            // The previous value was a bare issuance request, on this same
            // Keychain service/account. Preserve its exact retry identity.
            pending = try PhoneWatchRequest(from: decoder); relayBinding = nil; requiresNewRequest = false
        case 2:
            pending = try container.decode(PhoneWatchRequest?.self, forKey: .pending)
            relayBinding = try container.decode(WatchRelayScope?.self, forKey: .relayBinding)
            requiresNewRequest = try container.decodeIfPresent(Bool.self, forKey: .requiresNewRequest) ?? false
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                debugDescription: "Unsupported phone Watch setup version")
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(2, forKey: .version)
        try container.encode(pending, forKey: .pending)
        try container.encode(relayBinding, forKey: .relayBinding)
        try container.encode(requiresNewRequest, forKey: .requiresNewRequest)
    }
}
/// Pending setup contains installation authority. Production uses device-only Keychain.
protocol PhoneWatchRequestStorage {
    func load() throws -> PhoneWatchSetupRecord?
    /// Atomic replacement; failure preserves the previous committed value.
    func save(_ record: PhoneWatchSetupRecord) throws
}

@MainActor final class PhoneWatchModel: ObservableObject {
    @Published private(set) var notice: WatchCompanionNotice?
    @Published private(set) var pending: PhoneWatchRequest?
    @Published private(set) var relayBinding: WatchRelayScope?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let storage: any PhoneWatchRequestStorage
    private let clientFactory: @Sendable (ScoringEndpoint) -> MatchHTTPClient
    private let sendEnvelope: (WatchPairingEnvelope) throws -> Void
    private let onRelayBindingChanged: (WatchRelayScope?) -> Void
    private var record = PhoneWatchSetupRecord()
    private var relaySuppressed = false
    private var requiresNewRequest = false
    private var loaded = false
    private var active = false
    private var epoch = UUID()
    private var operation: Task<Void, Never>?

    init(storage: any PhoneWatchRequestStorage,
         clientFactory: @escaping @Sendable (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         onRelayBindingChanged: @escaping (WatchRelayScope?) -> Void = { _ in },
         sendEnvelope: @escaping (WatchPairingEnvelope) throws -> Void) {
        self.storage = storage; self.clientFactory = clientFactory; self.sendEnvelope = sendEnvelope
        self.onRelayBindingChanged = onRelayBindingChanged
    }
    func resume() {
        active = true
        do { try load() } catch { message = "Saved Watch setup could not be read. Try again." }
    }
    func suspend() async {
        active = false; epoch = UUID(); operation?.cancel()
        await operation?.value
    }
    func receive(_ notice: WatchCompanionNotice) {
        guard (try? WatchCompanionCodec.encodeNotice(notice)) != nil else { return }
        if let old = self.notice, old.deviceId != notice.deviceId { epoch = UUID(); operation?.cancel() }
        self.notice = notice
        do {
            try load()
            if let pending, confirmsPending(notice) {
                // Invalidate even if persistence fails: a late issuance response
                // must not resurrect or resend setup already confirmed by Watch.
                epoch = UUID(); operation?.cancel()
                suppressRelay()
                let binding = try Self.scope(for: pending)
                try persistRecord(PhoneWatchSetupRecord(relayBinding: binding))
                relaySuppressed = false; publishRelay(binding)
                message = "Watch reports that it is connected. Open Scorebug on your Watch to score."
            }
            // Application context and delegate Tasks have no freshness order.
            // Only matching pending confirmation may change this association;
            // WC peer changes invalidate it through peerChanged().
        } catch { message = "Watch confirmation could not be saved. Retry the saved setup." }
    }
    func peerChanged() {
        epoch = UUID(); notice = nil; operation?.cancel(); requiresNewRequest = true; suppressRelay()
        do {
            try load()
            try persistRecord(PhoneWatchSetupRecord(pending: pending, requiresNewRequest: true))
            message = pending == nil ? "Watch association changed. Connect your Watch again."
                : Self.describe(Failure.newRequestRequired)
        }
        catch { message = "Watch association could not be cleared. Reconnect your Watch before relaying scores." }
    }

    func connect(using connection: PhoneWatchConnection) async {
        guard active, !busy else { return }
        do {
            try load()
            guard !requiresNewRequest || pending == nil else { throw Failure.newRequestRequired }
            if let notice, confirmsPending(notice) { receive(notice); return }
        } catch { message = Self.describe(error); return }
        busy = true; message = nil
        let expected = epoch
        let task = Task { @MainActor [self] in
            do {
                try load()
                guard let target = notice?.deviceId else { throw Failure.noWatch }
                if let pending {
                    guard pending.request.watchDeviceId == target else { throw Failure.differentWatch }
                } else {
                    let client = clientFactory(try ScoringEndpoint(connection.endpoint))
                    guard !connection.installationToken.isEmpty else { throw Failure.noConnection }
                    let response = try await client.active(installationToken: connection.installationToken)
                    try check(expected)
                    guard let match = response.snapshot, match.status == .active else { throw Failure.noMatch }
                    let request = WatchPairingIssueRequest(pairingId: UUID().uuidString, watchDeviceId: target)
                    try persist(PhoneWatchRequest(connection: connection, gameId: match.id, request: request), startsNewRequest: true)
                }
                guard var saved = pending else { throw Failure.storage }
                let client = clientFactory(try ScoringEndpoint(saved.connection.endpoint))
                let offer = try await client.issueWatchPairing(gameId: saved.gameId, request: saved.request,
                                                               installationToken: saved.connection.installationToken)
                try check(expected)
                guard pending?.request == saved.request,
                      offer.pairingId == saved.request.pairingId, offer.watchDeviceId == saved.request.watchDeviceId,
                      offer.gameId == saved.gameId, offer.role == .score,
                      let expires = Self.date(offer.expiresAt), let server = Self.date(offer.serverTime) else { throw Failure.invalidResponse }
                guard expires > server else { throw Failure.expired }
                guard expires.timeIntervalSince(server) <= 300 else { throw Failure.invalidResponse }
                let envelope = WatchPairingEnvelope(endpoint: saved.connection.endpoint, offer: offer)
                _ = try WatchCompanionCodec.encodeEnvelope(envelope)
                saved.offer = offer
                try persist(saved)
                try check(expected)
                try sendEnvelope(envelope)
                message = "Setup sent. Open Scorebug on your Watch to finish connecting."
            } catch {
                if active, epoch == expected, !Task.isCancelled { message = Self.describe(error) }
            }
        }
        operation = task
        await task.value
        operation = nil; busy = false
    }
    func retry() async {
        guard active, !busy else { return }
        do { try load() } catch { message = "Saved Watch setup could not be read. Try again."; return }
        guard !requiresNewRequest else { message = Self.describe(Failure.newRequestRequired); return }
        if let notice, confirmsPending(notice) { receive(notice); return }
        if let pending { await connect(using: pending.connection) }
    }
    func resetRequest() {
        guard active, !busy else { return }
        do {
            try load()
            try persistRecord(PhoneWatchSetupRecord(relayBinding: relaySuppressed ? nil : record.relayBinding))
            requiresNewRequest = false; epoch = UUID()
            message = "Ready for a new setup request. Existing Watch access is unchanged."
        } catch { message = "The saved request could not be cleared. Try again." }
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard active, expected == epoch else { throw CancellationError() }
    }
    private func load() throws {
        guard !loaded else { return }
        do {
            let saved = try storage.load() ?? PhoneWatchSetupRecord()
            guard !saved.requiresNewRequest || saved.relayBinding == nil else { throw Failure.storage }
            if let value = saved.pending {
                guard value.version == 1, UUID(uuidString: value.request.pairingId) != nil,
                      UUID(uuidString: value.request.watchDeviceId) != nil,
                      !value.gameId.isEmpty, !value.connection.installationToken.isEmpty else { throw Failure.storage }
                let pendingScope = try Self.scope(for: value)
                guard pendingScope != saved.relayBinding else { throw Failure.storage }
                if let offer = value.offer {
                    guard offer.pairingId == value.request.pairingId, offer.watchDeviceId == value.request.watchDeviceId,
                          offer.gameId == value.gameId else { throw Failure.storage }
                    _ = try WatchCompanionCodec.encodeEnvelope(WatchPairingEnvelope(endpoint: value.connection.endpoint, offer: offer))
                }
            }
            if let binding = saved.relayBinding { try WatchRelayCodec.validateScope(binding) }
            record = saved; pending = saved.pending; loaded = true
            requiresNewRequest = requiresNewRequest || saved.requiresNewRequest
            if requiresNewRequest { suppressRelay() }
            else if !relaySuppressed { publishRelay(saved.relayBinding) }
        } catch { throw Failure.storage }
    }
    private func persist(_ value: PhoneWatchRequest?, startsNewRequest: Bool = false) throws {
        try persistRecord(PhoneWatchSetupRecord(pending: value,
            relayBinding: relaySuppressed ? nil : record.relayBinding,
            requiresNewRequest: startsNewRequest ? false : requiresNewRequest))
        if startsNewRequest { requiresNewRequest = false }
    }
    private func persistRecord(_ value: PhoneWatchSetupRecord) throws {
        do { try storage.save(value) } catch { throw Failure.storage }
        record = value; pending = value.pending
        if !relaySuppressed { publishRelay(value.relayBinding) }
    }
    private func confirmsPending(_ notice: WatchCompanionNotice) -> Bool {
        guard !requiresNewRequest, let pending else { return false }
        return notice.phase == .paired && notice.deviceId == pending.request.watchDeviceId
            && notice.gameId == pending.gameId && notice.pairingId == pending.request.pairingId
    }
    private static func scope(for request: PhoneWatchRequest) throws -> WatchRelayScope {
        let binding = WatchRelayScope(endpoint: try ScoringEndpoint(request.connection.endpoint).canonicalAddress,
            gameId: request.gameId, watchDeviceId: request.request.watchDeviceId, pairingId: request.request.pairingId)
        try WatchRelayCodec.validateScope(binding)
        return binding
    }
    private func publishRelay(_ value: WatchRelayScope?, force: Bool = false) {
        let changed = relayBinding != value
        relayBinding = value
        if changed || force { onRelayBindingChanged(value) }
    }
    private func suppressRelay() {
        relaySuppressed = true; publishRelay(nil, force: true)
    }
    private enum Failure: Error { case noWatch, noConnection, noMatch, differentWatch, invalidResponse, storage, expired, newRequestRequired }
    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.noWatch: "Open Scorebug on your paired Watch so it can identify itself."
        case Failure.noConnection: "Configure a server connection in Film or Score first."
        case Failure.noMatch: "Create an active match in Score before connecting your Watch."
        case Failure.differentWatch: "The saved setup belongs to another Watch. Start a new request for this Watch."
        case Failure.invalidResponse: "The server returned a different setup. Your saved request is kept for retry."
        case Failure.storage: "Watch setup could not be saved. No unsaved setup will be sent. Try again."
        case Failure.expired: "This setup request expired. Start a new request to connect your Watch."
        case Failure.newRequestRequired: "Watch association changed. Reset the saved setup before connecting your Watch again."
        case MatchClientError.unauthorized, MatchClientError.forbidden: "Server access was rejected. Check the saved server connection."
        default: "Watch setup is not confirmed. Retry the saved request when the connection is available."
        }
    }
    private static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = parser.date(from: text) { return result }
        parser.formatOptions = [.withInternetDateTime]; return parser.date(from: text)
    }
}
