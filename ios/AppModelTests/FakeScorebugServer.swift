import Foundation
import ScorebugCore

/// A tiny in-memory stand-in for the hosted Worker: Google sign-in (tickets and PKCE),
/// sessions, `/v1/me`, teams and invites, team match routes, scoring commands and match
/// codes, with the same volleyball rules as the server.
actor FakeScorebugServer {
    struct Match {
        var snapshot: MatchSnapshot
        var history: [(MatchScore, [MatchSetResult])] = []
        var receipts: [String: CommandOutcome] = [:]
    }

    struct FakeTeam {
        var team: Team
        var roles: [String: TeamRole] // personId → role
    }
    var people: [String: Person] = [:] // personId → person
    var sessions: [String: String] = [:] // token → personId
    var revokedSessions: [String] = []
    var tickets: [String: (personId: String, challenge: String)] = [:]
    var teams: [String: FakeTeam] = [:]
    var teamInvites: [String: (id: String, teamId: String, email: String?)] = [:] // code → invite
    var matchTeams: [String: String] = [:] // gameId → teamId
    var connections: [String: (personId: String, connection: YouTubeConnection)] = [:]
    var teamChannels: [String: String] = [:] // teamId → connectionId
    var matchYouTube: [String: MatchYouTube] = [:] // gameId → broadcast
    var youtubeTickets: [String: String] = [:] // ticket → personId
    /// What the next YouTube connect grants: a channel title, or nil for "no channel".
    var nextChannel: String? = "Wildcats Volleyball"
    var nextChannelStatus: YouTubeStatus = .ready
    var matches: [String: Match] = [:]
    var credentials: [String: MatchCredential] = [:] // token → credential
    var inviteCodes: [String: String] = [:] // code → gameId
    var requests: [(method: String, path: String, body: [String: Any]?)] = []
    var dropNextReply = false
    var failNextWith: URLError.Code?
    var creationBodies: [[String: Any]] = []

    func set(dropNextReply: Bool) { self.dropNextReply = dropNextReply }
    func set(failNextWith code: URLError.Code?) { failNextWith = code }
    func addMatch(_ snapshot: MatchSnapshot, team teamId: String? = nil) {
        matches[snapshot.id] = Match(snapshot: snapshot)
        matchTeams[snapshot.id] = teamId
    }
    /// A signed-in person with a session token, on `teamId` if given.
    @discardableResult func signedIn(_ email: String, token: String, team teamId: String? = nil, role: TeamRole = .owner) -> Person {
        let person = person(for: email)
        sessions[token] = person.id
        if let teamId { addTeam(teamId, name: "Cascade 14 Black", member: person.id, role: role) }
        return person
    }
    func addTeam(_ id: String, name: String, member personId: String, role: TeamRole) {
        var team = teams[id] ?? FakeTeam(team: Team(id: id, name: name, shortName: ShortName.derive(from: name), color: "#2563EB"), roles: [:])
        team.roles[personId] = role
        teams[id] = team
    }
    func addTeamInvite(code: String, teamId: String, email: String? = nil) { teamInvites[code] = ("inv-\(code)", teamId, email) }
    func revoke(token: String) { sessions[token] = nil }
    func setNextChannel(_ title: String?, status: YouTubeStatus = .ready) { nextChannel = title; nextChannelStatus = status }
    func setChannelStatus(_ id: String, _ status: YouTubeStatus) { connections[id]?.connection.status = status }
    func setWatchLink(_ gameId: String, _ link: MatchYouTube) { matchYouTube[gameId] = link }
    /// A channel connected by `email`, set as `teamId`'s channel.
    func addChannel(_ id: String, title: String, by email: String, team teamId: String? = nil, status: YouTubeStatus = .ready) {
        let person = person(for: email)
        connections[id] = (person.id, YouTubeConnection(id: id, channelId: "UC-\(id)", channelTitle: title, channelThumbnail: nil,
                                                       status: status, createdAt: "t", updatedAt: "t"))
        if let teamId { teamChannels[teamId] = id }
    }

    /// Google's YouTube consent and the Worker's callback leg, for the person whose token started it.
    func authorizeYouTube(_ url: URL) -> URL {
        let personId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        let ticket = String(repeating: "y", count: 40) + String(format: "%03d", youtubeTickets.count)
        youtubeTickets[ticket] = personId
        return URL(string: "scorebug://auth?purpose=youtube&status=ok&ticket=\(ticket)")!
    }

    private func teamYouTube(_ teamId: String) -> Any {
        guard let id = teamChannels[teamId], let entry = connections[id] else { return NSNull() }
        return ["connectionId": id, "channelTitle": entry.connection.channelTitle, "channelThumbnail": NSNull(),
                "status": entry.connection.status.rawValue, "connectedBy": entry.personId]
    }

    private func person(for email: String) -> Person {
        if let existing = people.values.first(where: { $0.email == email }) { return existing }
        let person = Person(id: "p-\(email.split(separator: "@")[0])", email: email, name: email.split(separator: "@")[0].capitalized, picture: nil)
        people[person.id] = person
        return person
    }

    /// Google's consent screen and the Worker's callback in one step: what
    /// `ASWebAuthenticationSession` hands back for `url` when `email` signs in.
    func authorize(_ url: URL, as email: String?) -> URL {
        guard let email else { return URL(string: "scorebug://auth?status=cancelled")! }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let challenge = items.first { $0.name == "challenge" }?.value ?? ""
        let invite = items.first { $0.name == "invite" }?.value.flatMap(TeamInviteCode.normalize)
        let link = invite.flatMap { teamInvites[$0] }.flatMap { $0.email == nil || $0.email == email ? $0 : nil }
        let person = person(for: email)
        if let link { addTeam(link.teamId, name: teams[link.teamId]?.team.name ?? "Team", member: person.id, role: teams[link.teamId]?.roles[person.id] ?? .member) }
        let ticket = String(repeating: "t", count: 40) + String(format: "%03d", tickets.count)
        tickets[ticket] = (person.id, challenge)
        return URL(string: "scorebug://auth?status=ok&ticket=\(ticket)")!
    }
    func snapshot(_ id: String) -> MatchSnapshot? { matches[id]?.snapshot }
    func issueCredential(gameId: String, deviceId: String, role: MatchRole) -> MatchCredential {
        let credential = MatchCredential(gameId: gameId, deviceId: deviceId, role: role, token: "cred-\(gameId)-\(deviceId)-\(role.rawValue)")
        credentials[credential.token] = credential
        return credential
    }
    func addInvite(code: String, gameId: String) { inviteCodes[code] = gameId }
    func operations(_ gameId: String) -> [String] {
        requests.filter { $0.method == "POST" && $0.path == "/v1/matches/\(gameId)/commands" }
            .compactMap { ($0.body?["operation"] as? [String: Any])?["type"] as? String }
    }

    static func now() -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        if let code = failNextWith { failNextWith = nil; throw URLError(code) }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        requests.append((method, path, body))
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let (status, object) = route(method: method, path: path, body: body ?? [:], token: token)
        if dropNextReply { dropNextReply = false; throw URLError(.networkConnectionLost) }
        let data = status == 204 ? Data() : try JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func encode<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func route(method: String, path: String, body: [String: Any], token: String?) -> (Int, Any) {
        let parts = path.split(separator: "/").map(String.init) // ["v1", ...]
        switch (method, Array(parts.dropFirst())) {
        case ("POST", ["auth", "session"]):
            let ticket = body["ticket"] as? String ?? "", verifier = body["verifier"] as? String ?? ""
            guard let pending = tickets.removeValue(forKey: ticket), PKCE.challenge(for: verifier) == pending.challenge,
                  let person = people[pending.personId] else { return (401, ["error": "ticket_invalid"]) }
            let token = "session-\(sessions.count + 1)"
            sessions[token] = person.id
            return (200, ["token": token, "person": encode(person), "serverTime": Self.now()])
        case ("DELETE", ["auth", "session"]):
            guard let token, sessions.removeValue(forKey: token) != nil else { return (401, ["error": "unauthorized"]) }
            revokedSessions.append(token)
            return (204, [:])
        case ("GET", ["me"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            let mine = teams.values.sorted { $0.team.id < $1.team.id }.compactMap { team in
                team.roles[person.id].map { TeamMembership(team: team.team, role: $0) }
            }
            return (200, ["person": encode(person), "teams": encode(mine), "serverTime": Self.now()])
        case ("POST", ["teams"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            let id = "team-\(teams.count + 1)"
            addTeam(id, name: body["name"] as? String ?? "", member: person.id, role: .owner)
            return (201, ["team": encode(teams[id]!.team), "role": "owner", "serverTime": Self.now()])
        case ("POST", ["team-invites", "accept"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            guard let code = TeamInviteCode.normalize(body["code"] as? String ?? ""), let invite = teamInvites[code] else {
                return (404, ["error": "invite_invalid"])
            }
            if let email = invite.email, email != person.email { return (403, ["error": "invite_email_mismatch"]) }
            addTeam(invite.teamId, name: "", member: person.id, role: teams[invite.teamId]?.roles[person.id] ?? .member)
            return (200, ["team": encode(teams[invite.teamId]!.team), "role": "member", "serverTime": Self.now()])
        case ("POST", ["youtube", "connect"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            return (200, ["url": "https://accounts.google.test/o/oauth2/v2/auth?state=\(person.id)", "serverTime": Self.now()])
        case ("POST", ["youtube", "connections"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            guard let owner = youtubeTickets.removeValue(forKey: body["ticket"] as? String ?? ""), owner == person.id else {
                return (404, ["error": "ticket_invalid"])
            }
            guard let title = nextChannel else { return (409, ["error": "youtube_no_channel"]) }
            // Reconnecting the same channel keeps its connection.
            let id = connections.first { $0.value.personId == person.id && $0.value.connection.channelTitle == title }?.key ?? "conn-\(connections.count + 1)"
            connections[id] = (person.id, YouTubeConnection(id: id, channelId: "UC-\(id)", channelTitle: title, channelThumbnail: nil,
                                                           status: nextChannelStatus, createdAt: "t", updatedAt: "t"))
            return (201, ["connection": encode(connections[id]!.connection), "serverTime": Self.now()])
        case ("GET", ["youtube", "connections"]):
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            let mine = connections.values.filter { $0.personId == person.id }.map(\.connection).sorted { $0.id < $1.id }
            return (200, ["connections": encode(mine), "serverTime": Self.now()])
        case ("POST", let p) where p.count == 4 && p[0] == "youtube" && p[3] == "check":
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            guard var entry = connections[p[2]], entry.personId == person.id else { return (404, ["error": "connection_not_found"]) }
            if entry.connection.status == .liveDisabled { entry.connection.status = .ready }
            connections[p[2]] = entry
            return (200, ["connection": encode(entry.connection), "serverTime": Self.now()])
        case ("PUT", let p) where p.count == 3 && p[0] == "teams" && p[2] == "youtube":
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            guard let role = teams[p[1]]?.roles[person.id] else { return (404, ["error": "team_not_found"]) }
            guard role == .owner else { return (403, ["error": "owner_required"]) }
            if let id = body["connectionId"] as? String {
                guard connections[id]?.personId == person.id else { return (404, ["error": "connection_not_found"]) }
                teamChannels[p[1]] = id
            } else {
                teamChannels[p[1]] = nil
            }
            return (200, ["youtube": teamYouTube(p[1]), "serverTime": Self.now()])
        case (_, let p) where p.count >= 2 && p[0] == "teams" && (p.count < 3 || p[2] != "matches"):
            return teamRoute(method: method, parts: p, body: body, token: token)
        case (_, let p) where p.count >= 3 && p[0] == "teams" && p[2] == "matches":
            guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
            guard teams[p[1]]?.roles[person.id] != nil else { return (404, ["error": "team_not_found"]) }
            return memberMatchRoute(method: method, teamId: p[1], rest: Array(p.dropFirst(3)), body: body)
        case ("POST", ["invites", "redeem"]):
            guard let code = InviteCode.normalize(body["code"] as? String ?? ""), let gameId = inviteCodes[code],
                  let match = matches[gameId] else { return (401, ["error": "invite_invalid"]) }
            guard match.snapshot.status == .active else { return (410, ["error": "match_ended"]) }
            let credential = issueCredential(gameId: gameId, deviceId: body["deviceId"] as? String ?? "", role: .score)
            return (200, ["credential": encode(credential), "snapshot": encode(match.snapshot), "serverTime": Self.now()])
        case ("GET", let p) where p.count == 2 && p[0] == "matches":
            guard let credential = credentials[token ?? ""], credential.gameId == p[1], let match = matches[p[1]] else { return (401, ["error": "unauthorized"]) }
            return (200, ["snapshot": encode(match.snapshot), "youtube": matchYouTube[p[1]].map(encode) ?? NSNull(), "serverTime": Self.now()])
        case ("GET", let p) where p.count == 4 && p[0] == "matches" && p[2] == "commands":
            guard let receipt = matches[p[1]]?.receipts[p[3]] else { return (404, ["error": "command_not_found"]) }
            return (200, encode(receipt))
        case ("POST", let p) where p.count == 3 && p[0] == "matches" && p[2] == "commands":
            guard let credential = credentials[token ?? ""], credential.gameId == p[1] else { return (401, ["error": "unauthorized"]) }
            let command = try! JSONDecoder().decode(MatchCommand.self, from: JSONSerialization.data(withJSONObject: body))
            let outcome = execute(command)
            return (outcome.accepted ? 200 : 409, encode(outcome))
        default:
            return (404, ["error": "not_found"])
        }
    }

    private func signedInPerson(_ token: String?) -> Person? { token.flatMap { sessions[$0] }.flatMap { people[$0] } }

    private func teamRoute(method: String, parts p: [String], body: [String: Any], token: String?) -> (Int, Any) {
        guard let person = signedInPerson(token) else { return (401, ["error": "unauthorized"]) }
        guard var team = teams[p[1]], let role = team.roles[person.id] else { return (404, ["error": "team_not_found"]) }
        let owner = role == .owner
        let invitesJSON = { self.invitesJSON(team.team.id) }
        switch (method, Array(p.dropFirst(2))) {
        case ("GET", []):
            let members = team.roles.sorted { ($0.value == .owner ? 0 : 1, $0.key) < ($1.value == .owner ? 0 : 1, $1.key) }.map { id, role in
                ["personId": id, "name": people[id]?.name ?? NSNull(), "email": people[id]?.email ?? "", "role": role.rawValue] as [String: Any]
            }
            var result: [String: Any] = ["team": encode(team.team), "role": role.rawValue, "members": members,
                                         "youtube": teamYouTube(team.team.id), "serverTime": Self.now()]
            if owner { result["invites"] = invitesJSON() }
            return (200, result)
        case ("PATCH", []):
            guard owner else { return (403, ["error": "owner_required"]) }
            if let name = body["name"] as? String { team.team.name = name }
            teams[team.team.id] = team
            return (200, ["team": encode(team.team), "serverTime": Self.now()])
        case ("POST", ["invites"]):
            guard owner else { return (403, ["error": "owner_required"]) }
            let code = "ABCD\(2345 + teamInvites.count)".replacingOccurrences(of: "0", with: "Z").replacingOccurrences(of: "1", with: "Y")
            addTeamInvite(code: code, teamId: team.team.id, email: body["email"] as? String)
            let invite = invitesJSON().first { $0["id"] as? String == "inv-\(code)" }!
            return (201, ["invite": invite, "code": "\(code.prefix(4))-\(code.suffix(4))", "link": "https://scorebug.live/invite/\(code)",
                          "serverTime": Self.now()])
        case ("DELETE", let rest) where rest.count == 2 && rest[0] == "invites":
            guard owner else { return (403, ["error": "owner_required"]) }
            guard let code = teamInvites.first(where: { $0.value.id == rest[1] })?.key else { return (404, ["error": "invite_not_found"]) }
            teamInvites[code] = nil
            return (200, ["invite": ["id": rest[1], "teamId": team.team.id, "email": NSNull(), "createdAt": "t", "expiresAt": "t", "revokedAt": "t"],
                          "serverTime": Self.now()])
        case ("DELETE", let rest) where rest.count == 2 && rest[0] == "members":
            guard rest[1] == person.id || owner else { return (403, ["error": "owner_required"]) }
            guard let targetRole = team.roles[rest[1]] else { return (404, ["error": "member_not_found"]) }
            if targetRole == .owner, team.roles.values.filter({ $0 == .owner }).count == 1 { return (409, ["error": "last_owner"]) }
            team.roles[rest[1]] = nil
            teams[team.team.id] = team
            return (204, [:])
        default:
            return (404, ["error": "not_found"])
        }
    }

    private func invitesJSON(_ teamId: String) -> [[String: Any]] {
        teamInvites.filter { $0.value.teamId == teamId }.sorted { $0.key < $1.key }.map { _, invite in
            ["id": invite.id, "teamId": invite.teamId, "email": invite.email ?? NSNull(), "createdAt": "2026-11-16T10:00:00.000Z",
             "expiresAt": "2099-01-01T00:00:00.000Z", "revokedAt": NSNull()]
        }
    }

    /// `/v1/teams/:teamId/matches/…`, after the membership check.
    private func memberMatchRoute(method: String, teamId: String, rest: [String], body: [String: Any]) -> (Int, Any) {
        let teamMatches = matches.filter { matchTeams[$0.key] == teamId }
        switch (method, rest) {
        case ("POST", []):
            creationBodies.append(body)
            if teamMatches.values.contains(where: { $0.snapshot.status == .active }) { return (409, ["error": "match_in_flight"]) }
            let creation = try! JSONDecoder().decode(MatchCreation.self, from: JSONSerialization.data(withJSONObject: body))
            let snapshot = MatchSnapshot(id: creation.id, createdAt: Self.now(), revision: 0, teams: creation.teams, rules: creation.rules,
                                         score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [],
                                         status: .active, endReason: nil, canUndo: false,
                                         scorer: MatchScorer(deviceId: creation.deviceId, epoch: 1),
                                         broadcast: MatchBroadcast(desired: .stopped, generation: 0),
                                         scorebugStyle: creation.scorebugStyle ?? .bar,
                                         output: MatchOutput(recordOnly: creation.recordOnly ?? false))
            matches[creation.id] = Match(snapshot: snapshot)
            matchTeams[creation.id] = teamId
            let credential = issueCredential(gameId: creation.id, deviceId: creation.deviceId, role: .score)
            return (201, ["snapshot": encode(snapshot), "credential": encode(credential), "serverTime": Self.now()])
        case ("GET", ["active"]):
            let active = teamMatches.values.first { $0.snapshot.status == .active }?.snapshot
            return (200, ["snapshot": active.map(encode) ?? NSNull(), "youtube": active.flatMap { matchYouTube[$0.id] }.map(encode) ?? NSNull(),
                          "serverTime": Self.now()])
        case ("POST", let p) where p.count == 2 && p[1] == "join":
            guard let match = teamMatches[p[0]] else { return (404, ["error": "match_not_found"]) }
            if match.snapshot.status == .ended { return (409, ["error": "match_ended"]) }
            let role = MatchRole(rawValue: body["role"] as? String ?? "") ?? .score
            let credential = issueCredential(gameId: p[0], deviceId: body["deviceId"] as? String ?? "", role: role)
            return (200, ["snapshot": encode(match.snapshot), "credential": encode(credential), "serverTime": Self.now()])
        case ("POST", let p) where p.count == 2 && p[1] == "invites":
            guard teamMatches[p[0]] != nil else { return (404, ["error": "match_not_found"]) }
            inviteCodes["K7P4QX"] = p[0]
            return (201, ["invite": ["id": "i1", "gameId": p[0], "createdAt": "t", "expiresAt": "t", "revokedAt": NSNull(), "redemptions": 0],
                          "code": "K7P-4QX", "link": "https://scorebug.live/join/K7P4QX", "expiresAt": "t"])
        default:
            return (404, ["error": "not_found"])
        }
    }

    private func execute(_ command: MatchCommand) -> CommandOutcome {
        var match = matches[command.gameId]!
        if let receipt = match.receipts[command.commandId] { return receipt }
        var s = match.snapshot
        func reject(_ code: String) -> CommandOutcome {
            let outcome = CommandOutcome(commandId: command.commandId, accepted: false, error: code, snapshot: s)
            match.receipts[command.commandId] = outcome; matches[command.gameId] = match
            return outcome
        }
        if command.operation != .takeOver,
           command.deviceId != s.scorer.deviceId || command.scorerEpoch != s.scorer.epoch { return reject("scorer_changed") }
        if command.expectedRevision != s.revision { return reject("revision_conflict") }
        if s.status == .ended { return reject("match_ended") }
        let setsToWin = (s.rules.bestOf + 1) / 2
        switch command.operation {
        case .takeOver:
            s.scorer = MatchScorer(deviceId: command.deviceId, epoch: s.scorer.epoch + 1)
        case .endMatch(let reason):
            s.status = .ended; s.endReason = reason
        case .undo:
            guard let previous = match.history.popLast() else { return reject("nothing_to_undo") }
            s.score = previous.0; s.completedSets = previous.1
        case .awardPoint(let side):
            if s.score.homeSets >= setsToWin || s.score.awaySets >= setsToWin { return reject("match_already_won") }
            match.history.append((s.score, s.completedSets))
            if side == .home { s.score.home += 1 } else { s.score.away += 1 }
        case .endSet:
            if s.score.homeSets >= setsToWin || s.score.awaySets >= setsToWin { return reject("match_already_won") }
            if s.score.home == s.score.away { return reject("tied_set") }
            guard let winner = Self.setWinner(s) else { return reject("set_not_won") }
            match.history.append((s.score, s.completedSets))
            s.completedSets.append(MatchSetResult(set: s.score.set, home: s.score.home, away: s.score.away, winner: winner, overrideReason: nil))
            if winner == .home { s.score.homeSets += 1 } else { s.score.awaySets += 1 }
            if s.score.homeSets < setsToWin && s.score.awaySets < setsToWin {
                s.score.home = 0; s.score.away = 0; s.score.set += 1
            }
        }
        s.revision += 1
        s.canUndo = !match.history.isEmpty
        let decided = s.score.homeSets >= setsToWin || s.score.awaySets >= setsToWin
        s.pendingSetEnd = s.status == .active && !decided ? Self.setWinner(s).map(PendingSetEnd.init(winner:)) : nil
        match.snapshot = s
        let outcome = CommandOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: s)
        match.receipts[command.commandId] = outcome
        matches[command.gameId] = match
        return outcome
    }

    static func setWinner(_ s: MatchSnapshot) -> MatchSide? {
        let target = s.score.set == s.rules.bestOf ? s.rules.decidingPointsToWin : s.rules.pointsToWin
        let high = max(s.score.home, s.score.away)
        guard s.score.home != s.score.away, high >= target, abs(s.score.home - s.score.away) >= s.rules.winBy else { return nil }
        return s.score.home > s.score.away ? .home : .away
    }

    /// Jumps a match straight to a score (test setup only).
    func force(_ gameId: String, home: Int, away: Int, set: Int = 1, homeSets: Int = 0, awaySets: Int = 0) {
        guard var match = matches[gameId] else { return }
        match.snapshot.score = MatchScore(home: home, away: away, set: set, homeSets: homeSets, awaySets: awaySets)
        match.snapshot.revision += 1
        match.snapshot.pendingSetEnd = Self.setWinner(match.snapshot).map(PendingSetEnd.init(winner:))
        matches[gameId] = match
    }
}
