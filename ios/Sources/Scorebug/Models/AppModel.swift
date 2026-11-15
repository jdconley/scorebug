import Combine
import Foundation
import ScorebugCore

/// App-wide state: the one server connection, which screen is showing, and
/// handling of `scorebug://connect` and `scorebug://join` links.
@MainActor final class AppModel: ObservableObject {
    enum Route: Equatable {
        case connect
        case home
        case filming(MatchSession)
        case scoring(MatchSession)
    }

    /// A link waiting for the person to confirm, so a stray link can't silently switch servers.
    enum PendingLink: Equatable, Identifiable {
        case connect(server: ScoringEndpoint, code: String)
        case join(JoinInput)
        var id: String {
            switch self {
            case .connect(let server, let code): "connect|\(server.url.absoluteString)|\(code)"
            case .join(let input): "join|\(input)"
            }
        }
    }

    typealias ClientFactory = (ScoringEndpoint) -> MatchHTTPClient

    @Published private(set) var config: ServerConfig?
    @Published private(set) var route: Route = .connect
    @Published var pendingLink: PendingLink?
    @Published private(set) var busy = false
    @Published var error: String?

    let preferences: AppPreferences
    private let store: SecureStore
    private let clientFactory: ClientFactory
    private let deviceName: () -> String
    private let newID: () -> String

    init(store: SecureStore, preferences: AppPreferences, clientFactory: @escaping ClientFactory = { MatchHTTPClient(endpoint: $0) },
         deviceName: @escaping () -> String, newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.preferences = preferences
        self.clientFactory = clientFactory
        self.deviceName = deviceName
        self.newID = newID
        config = try? store.value(ServerConfig.self, for: StoreKey.server)
        if let session = try? store.value(MatchSession.self, for: StoreKey.session) {
            route = session.kind == .filming ? .filming(session) : .scoring(session)
        } else {
            route = config?.isOwner == true ? .home : .connect
        }
    }

    func client(_ endpoint: String) throws -> MatchHTTPClient { clientFactory(try ScoringEndpoint(endpoint)) }

    var activeSession: MatchSession? {
        switch route {
        case .filming(let session), .scoring(let session): session
        default: nil
        }
    }

    // MARK: Links

    /// Opened from the URL scheme, a scanned QR code or a paste. Returns false when it isn't a Scorebug link.
    @discardableResult func open(_ text: String) -> Bool {
        switch ScorebugLink(string: text) {
        case .connect(let server, let code)?:
            pendingLink = .connect(server: server, code: code)
            return true
        case .join(let server, let code)?:
            pendingLink = .join(.link(server: server, code: code))
            return true
        case nil:
            return false
        }
    }

    func confirmPendingLink() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        switch link {
        case .connect(let server, let code): await enroll(server: server, code: code)
        case .join(let input): await join(input)
        }
    }

    // MARK: Enrollment

    /// Manual fallback: an address and the setup code from the server's link.
    @discardableResult func enroll(address: String, code: String) async -> Bool {
        do {
            let server = try ScoringEndpoint(address.contains("://") ? address : "https://\(address)")
            guard let code = ScorebugLink.normalizeSetupCode(code) else {
                error = "Enter the setup code from your server's link."
                return false
            }
            return await enroll(server: server, code: code)
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }

    /// Redeems a one-time setup code for an owner credential. The device ID is saved
    /// first, so retrying after a lost reply gets the same credential back.
    @discardableResult func enroll(server: ScoringEndpoint, code: String) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            let deviceId: String
            if let saved = try store.value(String.self, for: StoreKey.enrollmentDeviceId) { deviceId = saved }
            else { deviceId = newID(); try store.setValue(deviceId, for: StoreKey.enrollmentDeviceId) }
            let name = String(deviceName().prefix(64))
            let redeemed = try await clientFactory(server).redeemSetup(code: code, deviceId: deviceId, deviceName: name)
            let value = ServerConfig(endpoint: server.url.absoluteString, ownerToken: redeemed.token,
                                     deviceId: deviceId, deviceName: redeemed.device.name)
            try store.setValue(value, for: StoreKey.server)
            try store.setValue(String?.none, for: StoreKey.enrollmentDeviceId)
            config = value
            if activeSession == nil { route = .home }
            return true
        } catch MatchClientError.unauthorized {
            // Redeem answers 401 for a code it doesn't know.
            error = FriendlyError.message(code: "setup_code_invalid", status: 401)
            return false
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }

    func disconnect() {
        guard activeSession == nil else { return }
        try? store.setValue(ServerConfig?.none, for: StoreKey.server)
        config = nil
        route = .connect
    }

    // MARK: Joining someone else's match

    /// A pasted or typed invite. A bare code uses this phone's server.
    @discardableResult func join(text: String) async -> Bool {
        guard let input = JoinInput(text) else {
            error = "Enter the 6-character code, like K7P-4QX, or paste the invite link."
            return false
        }
        return await join(input)
    }

    @discardableResult func join(_ input: JoinInput) async -> Bool {
        guard !busy else { return false }
        let server: ScoringEndpoint
        let code: String
        switch input {
        case .link(let linkServer, let linkCode): server = linkServer; code = linkCode
        case .code(let bare):
            guard let config, let endpoint = try? ScoringEndpoint(config.endpoint) else {
                error = "Scan the invite QR code or paste its link: this phone doesn't know the server yet."
                return false
            }
            server = endpoint; code = bare
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = config ?? ServerConfig(endpoint: server.url.absoluteString, ownerToken: nil,
                                               deviceId: newID(), deviceName: String(deviceName().prefix(64)))
            if config == nil { try store.setValue(value, for: StoreKey.server); config = value }
            let redeemed = try await clientFactory(server).redeemInvite(code: code, deviceId: value.deviceId)
            guard redeemed.credential.role == .score, redeemed.credential.deviceId == value.deviceId,
                  redeemed.snapshot.id == redeemed.credential.gameId else { throw MatchClientError.invalidResponse }
            begin(MatchSession(kind: .scoring, endpoint: server.url.absoluteString, credential: redeemed.credential,
                               recordOnly: true, layout: CourtLayout(), startedAt: Date()))
            return true
        } catch MatchClientError.unauthorized {
            error = FriendlyError.message(code: "invite_invalid", status: 401)
            return false
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }

    // MARK: Sessions

    func begin(_ session: MatchSession) {
        do { try store.setValue(session, for: StoreKey.session) }
        catch { self.error = FriendlyError.message(error) }
        route = session.kind == .filming ? .filming(session) : .scoring(session)
    }

    func saveLayout(_ layout: CourtLayout) {
        guard var session = activeSession, session.layout != layout else { return }
        session.layout = layout
        try? store.setValue(session, for: StoreKey.session)
        route = session.kind == .filming ? .filming(session) : .scoring(session)
    }

    /// Leaves the match screen. A finished match becomes the Home card.
    func finish(lastSnapshot: MatchSnapshot?) {
        if let lastSnapshot, activeSession?.kind == .filming || lastSnapshot.status == .ended {
            preferences.lastMatch = MatchRecap(snapshot: lastSnapshot, date: Date())
        }
        try? store.setValue(MatchSession?.none, for: StoreKey.session)
        route = config?.isOwner == true ? .home : .connect
    }
}
