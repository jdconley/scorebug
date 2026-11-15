import Combine
import Foundation
import ScorebugCore

/// The Home status line: is the server reachable, and can it stream?
@MainActor final class HomeModel: ObservableObject {
    enum Connection: Equatable {
        case checking
        case connected(streamTarget: String?)
        case unreachable(String)
        case rejected
    }

    @Published private(set) var connection: Connection = .checking
    private let clientFactory: AppModel.ClientFactory

    init(clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.clientFactory = clientFactory
    }

    func refresh(_ config: ServerConfig?) async {
        guard let config, let token = config.ownerToken, let endpoint = try? ScoringEndpoint(config.endpoint) else {
            connection = .rejected
            return
        }
        let client = clientFactory(endpoint)
        do {
            _ = try await client.currentDevice(ownerToken: token)
            let destinations = (try? await client.destinations(ownerToken: token)) ?? []
            let target = destinations.first(where: \.isDefault) ?? destinations.first
            connection = .connected(streamTarget: target?.name)
        } catch MatchClientError.unauthorized {
            connection = .rejected
        } catch {
            connection = .unreachable(FriendlyError.message(error))
        }
    }

    /// "connected · YouTube ready"
    var detail: String {
        switch connection {
        case .checking: "checking…"
        case .connected(let target?): "connected · \(target) ready"
        case .connected(nil): "connected"
        case .unreachable: "not reachable"
        case .rejected: "needs a new setup link"
        }
    }

    var isHealthy: Bool { if case .connected = connection { true } else { false } }
}

/// In-memory scoring outbox for one-off commands (closing a leftover match).
final class MemoryPendingCommandStore: PendingCommandStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingMatchCommand?
    func load() throws -> PendingMatchCommand? { lock.withLock { value } }
    func save(_ pending: PendingMatchCommand?) throws { lock.withLock { value = pending } }
}
