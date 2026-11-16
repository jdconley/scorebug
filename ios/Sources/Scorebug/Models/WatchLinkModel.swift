import Combine
import Foundation
import ScorebugCore

/// The match's YouTube watch link, to show and share. It appears at the first Go Live and
/// never changes within a match, so once found there's nothing left to ask for.
@MainActor final class WatchLinkModel: ObservableObject {
    @Published private(set) var youtube: MatchYouTube?

    private let clientFactory: AppModel.ClientFactory
    init(clientFactory: @escaping AppModel.ClientFactory = { MatchHTTPClient(endpoint: $0) }) {
        self.clientFactory = clientFactory
    }

    var url: URL? { youtube?.url }

    /// A link the phone already has (the Go Live reply, or Home's active match).
    func found(_ link: MatchYouTube?) {
        guard let link, link.url != nil, youtube == nil else { return }
        youtube = link
    }

    /// Reads the match until its broadcast exists. Cancelled with the screen.
    func watch(_ session: MatchSession, every interval: Duration = .seconds(10)) async {
        guard let endpoint = try? ScoringEndpoint(session.endpoint) else { return }
        let client = clientFactory(endpoint)
        while youtube == nil, !Task.isCancelled {
            if let response = try? await client.snapshot(credential: session.credential) {
                found(response.youtube)
                if response.snapshot.status == .ended { return }
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    func shareText(teams: String?) -> String? {
        guard let url else { return nil }
        return "Watch \(teams ?? "our volleyball match") live on YouTube: \(url.absoluteString)"
    }
}
