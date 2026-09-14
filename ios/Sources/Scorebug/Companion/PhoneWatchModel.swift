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
/// Contains installation authority. Production adapter uses device-only Keychain.
protocol PhoneWatchRequestStorage {
    func load() throws -> PhoneWatchRequest?
    /// Atomic replacement; failure preserves the previous committed value.
    func save(_ request: PhoneWatchRequest?) throws
}

@MainActor final class PhoneWatchModel: ObservableObject {
    @Published private(set) var notice: WatchCompanionNotice?
    @Published private(set) var pending: PhoneWatchRequest?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let storage: any PhoneWatchRequestStorage
    private let clientFactory: @Sendable (ScoringEndpoint) -> MatchHTTPClient
    private let sendEnvelope: (WatchPairingEnvelope) throws -> Void
    private var loaded = false
    private var active = false
    private var epoch = UUID()
    private var operation: Task<Void, Never>?

    init(storage: any PhoneWatchRequestStorage,
         clientFactory: @escaping @Sendable (ScoringEndpoint) -> MatchHTTPClient = { MatchHTTPClient(endpoint: $0) },
         sendEnvelope: @escaping (WatchPairingEnvelope) throws -> Void) {
        self.storage = storage; self.clientFactory = clientFactory; self.sendEnvelope = sendEnvelope
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
            if let pending, notice.phase == .paired, notice.deviceId == pending.request.watchDeviceId,
               notice.gameId == pending.gameId, notice.pairingId == pending.request.pairingId {
                try persist(nil)
                epoch = UUID()
                message = "Watch reports that it is connected. Open Scorebug on your Watch to score."
            }
        } catch { message = "Watch confirmation could not be saved. Retry the saved setup." }
    }
    func peerChanged() { epoch = UUID(); notice = nil; operation?.cancel() }

    func connect(using connection: PhoneWatchConnection) async {
        guard active, !busy else { return }
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
                    try persist(PhoneWatchRequest(connection: connection, gameId: match.id, request: request))
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
        do { try load() } catch { message = "Saved Watch setup could not be read. Try again."; return }
        if let pending { await connect(using: pending.connection) }
    }
    func resetRequest() {
        guard active, !busy else { return }
        do {
            try load(); try persist(nil); epoch = UUID()
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
            let value = try storage.load()
            if let value {
                guard value.version == 1, UUID(uuidString: value.request.pairingId) != nil,
                      UUID(uuidString: value.request.watchDeviceId) != nil,
                      !value.gameId.isEmpty, !value.connection.installationToken.isEmpty else { throw Failure.storage }
                _ = try ScoringEndpoint(value.connection.endpoint)
                if let offer = value.offer {
                    guard offer.pairingId == value.request.pairingId, offer.watchDeviceId == value.request.watchDeviceId,
                          offer.gameId == value.gameId else { throw Failure.storage }
                    _ = try WatchCompanionCodec.encodeEnvelope(WatchPairingEnvelope(endpoint: value.connection.endpoint, offer: offer))
                }
            }
            pending = value; loaded = true
        } catch { throw Failure.storage }
    }
    private func persist(_ value: PhoneWatchRequest?) throws {
        do { try storage.save(value) } catch { throw Failure.storage }
        pending = value
    }
    private enum Failure: Error { case noWatch, noConnection, noMatch, differentWatch, invalidResponse, storage, expired }
    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.noWatch: "Open Scorebug on your paired Watch so it can identify itself."
        case Failure.noConnection: "Configure a server connection in Film or Score first."
        case Failure.noMatch: "Create an active match in Score before connecting your Watch."
        case Failure.differentWatch: "The saved setup belongs to another Watch. Start a new request for this Watch."
        case Failure.invalidResponse: "The server returned a different setup. Your saved request is kept for retry."
        case Failure.storage: "Watch setup could not be saved. No unsaved setup will be sent. Try again."
        case Failure.expired: "This setup request expired. Start a new request to connect your Watch."
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
