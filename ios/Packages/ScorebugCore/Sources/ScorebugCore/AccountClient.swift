import Foundation

/// Sign-in, the person and their teams (`apps/control-plane/src/worker`). Every call
/// but sign-in itself sends the session token as a bearer token.
extension MatchHTTPClient {
    /// The page `ASWebAuthenticationSession` opens. It sends the person to Google and
    /// back to `scorebug://auth`. `invite` is a team invite code that lets them in.
    public func signInURL(challenge: String, invite: String? = nil) -> URL {
        var components = URLComponents(url: serverURL.appendingPathComponent("v1/auth/google/start"),
                                       resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "challenge", value: challenge)]
        if let invite { items.append(URLQueryItem(name: "invite", value: invite)) }
        components.queryItems = items
        return components.url!
    }

    /// Trades the one-time ticket from the callback, plus the PKCE verifier only this
    /// app knows, for a session token. A 401 (`ticket_invalid`) means start over.
    public func createSession(ticket: String, verifier: String, deviceName: String) async throws -> SignedIn {
        struct Request: Encodable { let ticket: String; let verifier: String; let deviceName: String? }
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return try await send(root: ["auth"], path: ["session"], method: "POST", token: nil,
                              body: JSONEncoder().encode(Request(ticket: ticket, verifier: verifier,
                                                                 deviceName: name.isEmpty ? nil : name)))
    }

    /// Revokes the session token on the server.
    public func deleteSession(token: String) async throws {
        let _: NoContent = try await send(root: ["auth"], path: ["session"], method: "DELETE", token: token)
    }

    public func me(token: String) async throws -> Me {
        try await send(root: ["me"], path: [], token: token)
    }

    /// Deletes the account for good: the person, every session, their YouTube connections, and
    /// teams no one else is on. Teams with other people keep going without them.
    public func deleteAccount(token: String) async throws {
        let _: NoContent = try await send(root: ["me"], path: [], method: "DELETE", token: token)
    }

    // MARK: Teams

    public func createTeam(name: String, token: String) async throws -> TeamJoined {
        struct Request: Encodable { let name: String }
        return try await send(root: ["teams"], path: [], method: "POST", token: token,
                              body: JSONEncoder().encode(Request(name: name)))
    }

    public func teamDetail(_ teamId: String, token: String) async throws -> TeamDetail {
        try await send(root: ["teams"], path: [teamId], token: token)
    }

    /// Owner only.
    public func renameTeam(_ teamId: String, name: String, token: String) async throws -> Team {
        struct Request: Encodable { let name: String }
        struct Response: Decodable { let team: Team }
        let response: Response = try await send(root: ["teams"], path: [teamId], method: "PATCH", token: token,
                                                body: JSONEncoder().encode(Request(name: name)))
        return response.team
    }

    /// Owner only. With an email, only that Google account can accept it.
    public func createTeamInvite(_ teamId: String, email: String?, token: String) async throws -> TeamInviteIssued {
        struct Request: Encodable { let email: String? }
        return try await send(root: ["teams"], path: [teamId, "invites"], method: "POST", token: token,
                              body: JSONEncoder().encode(Request(email: email)))
    }

    /// Owner only.
    public func revokeTeamInvite(_ teamId: String, inviteId: String, token: String) async throws {
        let _: NoContent = try await send(root: ["teams"], path: [teamId, "invites", inviteId], method: "DELETE", token: token)
    }

    /// Owners remove anyone; a member removes only themself (leaving). 409 `last_owner` keeps one owner.
    public func removeMember(_ teamId: String, personId: String, token: String) async throws {
        let _: NoContent = try await send(root: ["teams"], path: [teamId, "members", personId], method: "DELETE", token: token)
    }

    /// Joins the team the invite belongs to. 403 `invite_email_mismatch` when it was for another email.
    public func acceptTeamInvite(code: String, token: String) async throws -> TeamJoined {
        struct Request: Encodable { let code: String }
        return try await send(root: ["team-invites"], path: ["accept"], method: "POST", token: token,
                              body: JSONEncoder().encode(Request(code: code)))
    }
}
