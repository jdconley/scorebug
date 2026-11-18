import XCTest
@testable import ScorebugCore

final class AccountClientTests: XCTestCase {
    private let person = ##"{"id":"p1","email":"jd@example.com","name":"JD","picture":null}"##
    private let team = ##"{"id":"t1","name":"Cascade 14 Black","shortName":"CASCADE","color":"#2563EB","createdAt":"2026-11-16T10:00:00.000Z"}"##

    // MARK: PKCE

    func testPKCEMatchesTheRFC7636Example() {
        // RFC 7636 appendix B.
        let bytes: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                              22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        let pkce = PKCE.make(bytes: bytes)
        XCTAssertEqual(pkce.verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEFitsTheServerGrammarAndIsFreshEachTime() {
        let a = PKCE.make(), b = PKCE.make()
        XCTAssertNotEqual(a.verifier, b.verifier)
        for pkce in [a, b] {
            // Worker: VERIFIER_PATTERN /^[A-Za-z0-9._~-]{43,128}$/, CHALLENGE_PATTERN /^[A-Za-z0-9_-]{43}$/.
            XCTAssertNotNil(pkce.verifier.range(of: ##"^[A-Za-z0-9._~-]{43,128}$"##, options: .regularExpression))
            XCTAssertNotNil(pkce.challenge.range(of: ##"^[A-Za-z0-9_-]{43}$"##, options: .regularExpression))
            XCTAssertEqual(PKCE.challenge(for: pkce.verifier), pkce.challenge)
        }
    }

    // MARK: Callback

    func testSignInCallbackStatuses() throws {
        let ticket = String(repeating: "a", count: 40) + "_-Z"
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=ok&ticket=\(ticket)"))), .ok(ticket: ticket))
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=cancelled"))), .cancelled)
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=error"))), .error)
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=future"))), .error)
        // An ok without a well-formed ticket is an error, not a sign-in.
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=ok"))), .error)
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=ok&ticket=short"))), .error)
        XCTAssertEqual(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://auth?status=ok&ticket=\(ticket)&ticket=\(ticket)"))), .error)
        XCTAssertNil(SignInCallback(url: try XCTUnwrap(URL(string: "scorebug://join?status=ok"))))
        XCTAssertNil(SignInCallback(url: try XCTUnwrap(URL(string: "https://auth?status=ok"))))
    }

    // MARK: Requests

    func testSignInURLCarriesChallengeAndInvite() throws {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://scorebug.live"), transport: { _ in fatalError() })
        XCTAssertEqual(client.signInURL(challenge: "abc").absoluteString,
                       "https://scorebug.live/v1/auth/google/start?challenge=abc")
        XCTAssertEqual(client.signInURL(challenge: "abc", invite: "ABCD2345").absoluteString,
                       "https://scorebug.live/v1/auth/google/start?challenge=abc&invite=ABCD2345")
    }

    func testTicketExchangeSendsVerifierAndDeviceNameWithoutAuthorization() async throws {
        let client = try client(status: 200, body: ##"{"token":"session-token","person":\##(person),"serverTime":"t"}"##) { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8787/v1/auth/session")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
            XCTAssertEqual(body, ["ticket": "tkt", "verifier": "ver", "deviceName": "JD's iPhone"])
        }
        let signedIn = try await client.createSession(ticket: "tkt", verifier: "ver", deviceName: " JD's iPhone ")
        XCTAssertEqual(signedIn.token, "session-token")
        XCTAssertEqual(signedIn.person.displayName, "JD")
    }

    func testInvalidTicketIsUnauthorized() async throws {
        let client = try client(status: 401, body: ##"{"error":"ticket_invalid"}"##)
        do { _ = try await client.createSession(ticket: "t", verifier: "v", deviceName: ""); XCTFail("Should throw") }
        catch let error as MatchClientError { XCTAssertEqual(error, .unauthorized) }
    }

    func testSignOutRevokesWithTheSessionToken() async throws {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:8787"), transport: { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/session")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        try await client.deleteSession(token: "session")
    }

    func testMeDecodesTeamsAndRoles() async throws {
        let body = ##"{"person":\##(person),"teams":[{"id":"t1","name":"Cascade 14 Black","shortName":"CASCADE","color":"#2563EB","role":"owner"}],"serverTime":"t"}"##
        let client = try client(status: 200, body: body) { request in
            XCTAssertEqual(request.url?.path, "/v1/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        }
        let me = try await client.me(token: "session")
        XCTAssertEqual(me.teams, [TeamMembership(id: "t1", name: "Cascade 14 Black", shortName: "CASCADE", color: "#2563EB", role: .owner)])
    }

    func testTeamRoutes() async throws {
        var seen: [String] = []
        let responses: [String: (Int, String)] = [
            "POST /v1/teams": (201, ##"{"team":\##(team),"role":"owner","serverTime":"t"}"##),
            "GET /v1/teams/t1": (200, ##"{"team":\##(team),"role":"owner","members":[{"personId":"p1","name":"JD","email":"jd@example.com","role":"owner"}],"invites":[{"id":"i1","teamId":"t1","email":null,"createdAt":"2026-11-16T10:00:00.000Z","expiresAt":"2026-11-30T10:00:00.000Z","revokedAt":null}],"serverTime":"t"}"##),
            "PATCH /v1/teams/t1": (200, ##"{"team":\##(team),"serverTime":"t"}"##),
            "POST /v1/teams/t1/invites": (201, ##"{"invite":{"id":"i2","teamId":"t1","email":"mom@example.com","createdAt":"t","expiresAt":"t","revokedAt":null},"code":"ABCD-2345","link":"https://scorebug.live/invite/ABCD2345","serverTime":"t"}"##),
            "DELETE /v1/teams/t1/invites/i2": (200, ##"{"invite":{"id":"i2","teamId":"t1","email":null,"createdAt":"t","expiresAt":"t","revokedAt":"t"},"serverTime":"t"}"##),
            "DELETE /v1/teams/t1/members/p2": (204, ""),
            "POST /v1/team-invites/accept": (200, ##"{"team":\##(team),"role":"member","serverTime":"t"}"##),
        ]
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:8787"), transport: { request in
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            seen.append(key + " " + String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s")
            let (status, body) = try XCTUnwrap(responses[key], key)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let created = try await client.createTeam(name: "Cascade 14 Black", token: "s")
        XCTAssertEqual(created.role, .owner)
        let detail = try await client.teamDetail("t1", token: "s")
        XCTAssertEqual(detail.members.first?.displayName, "JD")
        XCTAssertEqual(detail.invites?.first?.isLive(now: ServerDate.parse("2026-11-20T00:00:00Z")!), true)
        XCTAssertEqual(detail.invites?.first?.isLive(now: ServerDate.parse("2026-12-01T00:00:00Z")!), false)
        let renamed = try await client.renameTeam("t1", name: "Cascade", token: "s")
        XCTAssertEqual(renamed.id, "t1")
        let issued = try await client.createTeamInvite("t1", email: "mom@example.com", token: "s")
        XCTAssertEqual(ScorebugLink(string: issued.link), .teamInvite(code: "ABCD2345"))
        _ = try await client.createTeamInvite("t1", email: nil, token: "s")
        try await client.revokeTeamInvite("t1", inviteId: "i2", token: "s")
        try await client.removeMember("t1", personId: "p2", token: "s")
        let accepted = try await client.acceptTeamInvite(code: "ABCD2345", token: "s")
        XCTAssertEqual(accepted.role, .member)
        XCTAssertEqual(seen, [
            ##"POST /v1/teams {"name":"Cascade 14 Black"}"##,
            "GET /v1/teams/t1 ",
            ##"PATCH /v1/teams/t1 {"name":"Cascade"}"##,
            ##"POST /v1/teams/t1/invites {"email":"mom@example.com"}"##,
            "POST /v1/teams/t1/invites {}",
            "DELETE /v1/teams/t1/invites/i2 ",
            "DELETE /v1/teams/t1/members/p2 ",
            ##"POST /v1/team-invites/accept {"code":"ABCD2345"}"##,
        ])
    }

    func testMemberMatchRoutesAreAlwaysTeamScoped() async throws {
        var paths: [String] = []
        let base = MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:8787"), transport: { request in
            paths.append(request.url!.path)
            return (Data(##"{"snapshot":null,"serverTime":"t"}"##.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await base.team("t1").active(token: "s")
        XCTAssertEqual(paths, ["/v1/teams/t1/matches/active"])
        for client in [base, base.team("../x")] {
            do { _ = try await client.active(token: "s"); XCTFail("Should throw") }
            catch let error as MatchClientError { XCTAssertEqual(error, .invalidIdentifier) }
        }
        XCTAssertEqual(paths.count, 1, "nothing is sent without a valid team")
    }

    private func client(status: Int, body: String, inspect: @escaping (URLRequest) throws -> Void = { _ in }) throws -> MatchHTTPClient {
        MatchHTTPClient(endpoint: try ScoringEndpoint("http://localhost:8787"), transport: { request in
            try inspect(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}
