import XCTest
@testable import ScorebugCore

final class YouTubeClientTests: XCTestCase {
    private let connection = ##"{"id":"c1","channelId":"UC123","channelTitle":"Wildcats Volleyball","channelThumbnail":"https://yt3.example/t.jpg","status":"live_disabled","createdAt":"t","updatedAt":"t"}"##
    private let ticket = String(repeating: "y", count: 43)

    func testCallbackStatusesAndPurpose() throws {
        func parse(_ text: String) -> YouTubeCallback? { YouTubeCallback(url: URL(string: text)!) }
        XCTAssertEqual(parse("scorebug://auth?purpose=youtube&status=ok&ticket=\(ticket)"), .ok(ticket: ticket))
        XCTAssertEqual(parse("scorebug://auth?purpose=youtube&status=cancelled"), .cancelled)
        XCTAssertEqual(parse("scorebug://auth?purpose=youtube&status=scope_denied"), .scopeDenied)
        XCTAssertEqual(parse("scorebug://auth?purpose=youtube&status=error"), .error)
        XCTAssertEqual(parse("scorebug://auth?purpose=youtube&status=ok&ticket=short"), .error)
        XCTAssertNil(parse("scorebug://auth?status=ok&ticket=\(ticket)"), "a sign-in callback isn't a channel")
        // And a channel callback is never mistaken for a sign-in.
        XCTAssertNil(SignInCallback(url: URL(string: "scorebug://auth?purpose=youtube&status=ok&ticket=\(ticket)")!))
    }

    func testConnectClaimListCheckAndDelete() async throws {
        var seen: [String] = []
        let responses: [String: (Int, String)] = [
            "POST /v1/youtube/connect": (200, ##"{"url":"https://accounts.google.com/o/oauth2/v2/auth?state=s","serverTime":"t"}"##),
            "POST /v1/youtube/connections": (201, ##"{"connection":\##(connection),"serverTime":"t"}"##),
            "GET /v1/youtube/connections": (200, ##"{"connections":[\##(connection)],"serverTime":"t"}"##),
            "POST /v1/youtube/connections/c1/check": (200, ##"{"connection":\##(connection.replacingOccurrences(of: "live_disabled", with: "ready")),"serverTime":"t"}"##),
            "DELETE /v1/youtube/connections/c1": (204, ""),
        ]
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://scorebug.live"), transport: { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            seen.append(key + " " + String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s")
            let (status, body) = try XCTUnwrap(responses[key], key)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let url = try await client.youtubeConnectURL(token: "s")
        XCTAssertEqual(url.host, "accounts.google.com")
        let claimed = try await client.claimYouTubeConnection(ticket: ticket, token: "s")
        XCTAssertEqual(claimed.status, .liveDisabled)
        XCTAssertEqual(claimed.channelTitle, "Wildcats Volleyball")
        let list = try await client.youtubeConnections(token: "s")
        XCTAssertEqual(list.map(\.id), ["c1"])
        let checked = try await client.checkYouTubeConnection("c1", token: "s")
        XCTAssertEqual(checked.status, .ready)
        try await client.deleteYouTubeConnection("c1", token: "s")
        XCTAssertEqual(seen, [
            "POST /v1/youtube/connect {}",
            "POST /v1/youtube/connections {\"ticket\":\"\(ticket)\"}",
            "GET /v1/youtube/connections ",
            "POST /v1/youtube/connections/c1/check {}",
            "DELETE /v1/youtube/connections/c1 ",
        ])
    }

    func testTeamChannelSetAndClear() async throws {
        var bodies: [String] = []
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://scorebug.live"), transport: { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/teams/t1/youtube")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            bodies.append(body)
            let reply = body.contains("null") ? ##"{"youtube":null,"serverTime":"t"}"##
                : ##"{"youtube":{"connectionId":"c1","channelTitle":"Wildcats","channelThumbnail":null,"status":"needs_reconnect","connectedBy":"p1"},"serverTime":"t"}"##
            return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let set = try await client.setTeamChannel("t1", connectionId: "c1", token: "s")
        XCTAssertEqual(set?.status, .needsReconnect)
        XCTAssertEqual(set?.connectedBy, "p1")
        let cleared = try await client.setTeamChannel("t1", connectionId: nil, token: "s")
        XCTAssertNil(cleared)
        XCTAssertEqual(bodies, [##"{"connectionId":"c1"}"##, ##"{"connectionId":null}"##])
    }

    func testTeamDetailAndMatchReadsCarryYouTube() throws {
        let team = ##"{"id":"t1","name":"Cascade","shortName":"CASCADE","color":"#2563EB","createdAt":"t"}"##
        let none = try JSONDecoder().decode(TeamDetail.self, from: Data(##"{"team":\##(team),"role":"member","members":[],"youtube":null}"##.utf8))
        XCTAssertNil(none.youtube)
        let unknown = try JSONDecoder().decode(TeamYouTube.self, from: Data(##"{"connectionId":"c","channelTitle":"W","status":"future","connectedBy":"p"}"##.utf8))
        XCTAssertEqual(unknown.status, .needsReconnect, "an unknown status never reads as ready")

        let youtube = MatchYouTube(broadcastId: "abc123", watchUrl: "https://www.youtube.com/watch?v=abc123",
                                   channelTitle: "Wildcats", channelThumbnail: nil, privacy: "unlisted")
        XCTAssertEqual(youtube.url?.absoluteString, "https://www.youtube.com/watch?v=abc123")
        for bad in ["http://www.youtube.com/watch?v=x", "https://evil.example/watch?v=x", "https://youtube.com.evil.example/x", "nope"] {
            var other = youtube; other.watchUrl = bad
            XCTAssertNil(other.url, bad)
        }
        let active = try JSONDecoder().decode(ActiveMatchResponse.self, from: Data(##"{"snapshot":null,"youtube":{"broadcastId":"abc123","watchUrl":"https://www.youtube.com/watch?v=abc123","channelTitle":"Wildcats","channelThumbnail":null,"privacy":"unlisted"},"serverTime":"t"}"##.utf8))
        XCTAssertEqual(active.youtube, youtube)
        let older = try JSONDecoder().decode(ActiveMatchResponse.self, from: Data(##"{"snapshot":null,"serverTime":"t"}"##.utf8))
        XCTAssertNil(older.youtube)
    }
}
