import Foundation
import ScorebugCore

/// A tiny in-memory stand-in for the control plane: setup, destinations, matches,
/// scoring commands and invites, with the same volleyball rules as the server.
actor FakeScorebugServer {
    struct Match {
        var snapshot: MatchSnapshot
        var history: [(MatchScore, [MatchSetResult])] = []
        var receipts: [String: CommandOutcome] = [:]
    }

    var setupCodes: Set<String> = ["setup-code-123456789012"]
    var ownerTokens: [String: String] = [:] // token → deviceId
    var redeemedDevices: [String: String] = [:] // deviceId → token
    var destinations: [Destination] = [Destination(id: "yt", name: "YouTube", rtmpUrl: "rtmps://a.rtmp.youtube.com/live2",
                                                   streamKeyLast4: "abcd", isDefault: true, createdAt: "t", updatedAt: "t")]
    var matches: [String: Match] = [:]
    var credentials: [String: MatchCredential] = [:] // token → credential
    var inviteCodes: [String: String] = [:] // code → gameId
    var requests: [(method: String, path: String, body: [String: Any]?)] = []
    var dropNextReply = false
    var failNextWith: URLError.Code?
    var creationBodies: [[String: Any]] = []

    func set(dropNextReply: Bool) { self.dropNextReply = dropNextReply }
    func set(failNextWith code: URLError.Code?) { failNextWith = code }
    func addMatch(_ snapshot: MatchSnapshot) { matches[snapshot.id] = Match(snapshot: snapshot) }
    func setDestinations(_ list: [Destination]) { destinations = list }
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
        let data = try JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func encode<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func isOwner(_ token: String?) -> Bool { token.map { ownerTokens[$0] != nil } ?? false }

    private func route(method: String, path: String, body: [String: Any], token: String?) -> (Int, Any) {
        let parts = path.split(separator: "/").map(String.init) // ["v1", ...]
        switch (method, Array(parts.dropFirst())) {
        case ("POST", ["setup", "redeem"]):
            let code = body["code"] as? String ?? "", deviceId = body["deviceId"] as? String ?? ""
            if let existing = redeemedDevices[deviceId] {
                return (200, ["device": device(deviceId, body), "token": existing, "serverTime": Self.now()])
            }
            guard setupCodes.remove(code) != nil else { return (401, ["error": "setup_code_invalid"]) }
            let token = "owner-\(deviceId)"
            ownerTokens[token] = deviceId; redeemedDevices[deviceId] = token
            return (200, ["device": device(deviceId, body), "token": token, "serverTime": Self.now()])
        case ("GET", ["devices", "me"]):
            guard let token, let id = ownerTokens[token] else { return (401, ["error": "unauthorized"]) }
            return (200, ["role": "owner", "legacy": false, "device": device(id, ["deviceName": "Phone"])])
        case ("GET", ["destinations"]):
            guard isOwner(token) else { return (401, ["error": "unauthorized"]) }
            return (200, ["destinations": encode(destinations), "serverTime": Self.now()])
        case ("POST", ["matches"]):
            guard isOwner(token) else { return (401, ["error": "unauthorized"]) }
            creationBodies.append(body)
            if matches.values.contains(where: { $0.snapshot.status == .active }) { return (409, ["error": "match_in_flight"]) }
            let creation = try! JSONDecoder().decode(MatchCreation.self, from: JSONSerialization.data(withJSONObject: body))
            let snapshot = MatchSnapshot(id: creation.id, createdAt: Self.now(), revision: 0, teams: creation.teams, rules: creation.rules,
                                         score: MatchScore(home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0), completedSets: [],
                                         status: .active, endReason: nil, canUndo: false,
                                         scorer: MatchScorer(deviceId: creation.deviceId, epoch: 1),
                                         broadcast: MatchBroadcast(desired: .stopped, generation: 0),
                                         scorebugStyle: creation.scorebugStyle ?? .bar,
                                         output: MatchOutput(destinationId: creation.destinationId, recordOnly: creation.recordOnly ?? false))
            matches[creation.id] = Match(snapshot: snapshot)
            let credential = issueCredential(gameId: creation.id, deviceId: creation.deviceId, role: .score)
            return (201, ["snapshot": encode(snapshot), "credential": encode(credential), "serverTime": Self.now()])
        case ("GET", ["matches", "active"]):
            guard isOwner(token) else { return (401, ["error": "unauthorized"]) }
            let active = matches.values.first { $0.snapshot.status == .active }?.snapshot
            return (200, ["snapshot": active.map(encode) ?? NSNull(), "serverTime": Self.now()])
        case ("POST", let p) where p.count == 3 && p[0] == "matches" && p[2] == "join":
            guard isOwner(token), let match = matches[p[1]] else { return (401, ["error": "unauthorized"]) }
            let role = MatchRole(rawValue: body["role"] as? String ?? "") ?? .score
            let credential = issueCredential(gameId: p[1], deviceId: body["deviceId"] as? String ?? "", role: role)
            return (200, ["snapshot": encode(match.snapshot), "credential": encode(credential), "serverTime": Self.now()])
        case ("POST", let p) where p.count == 3 && p[0] == "matches" && p[2] == "invites":
            guard isOwner(token) || credentials[token ?? ""]?.role == .capture else { return (401, ["error": "unauthorized"]) }
            inviteCodes["K7P4QX"] = p[1]
            return (201, ["invite": ["id": "i1", "gameId": p[1], "createdAt": "t", "expiresAt": "t", "revokedAt": NSNull(), "redemptions": 0],
                          "code": "K7P-4QX", "link": "scorebug://join?server=https%3A%2F%2Fscore.example.com&code=K7P4QX", "expiresAt": "t"])
        case ("POST", ["invites", "redeem"]):
            guard let code = InviteCode.normalize(body["code"] as? String ?? ""), let gameId = inviteCodes[code],
                  let match = matches[gameId] else { return (401, ["error": "invite_invalid"]) }
            guard match.snapshot.status == .active else { return (410, ["error": "match_ended"]) }
            let credential = issueCredential(gameId: gameId, deviceId: body["deviceId"] as? String ?? "", role: .score)
            return (200, ["credential": encode(credential), "snapshot": encode(match.snapshot), "serverTime": Self.now()])
        case ("GET", let p) where p.count == 2 && p[0] == "matches":
            guard let credential = credentials[token ?? ""], credential.gameId == p[1], let match = matches[p[1]] else { return (401, ["error": "unauthorized"]) }
            return (200, ["snapshot": encode(match.snapshot), "serverTime": Self.now()])
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

    private func device(_ id: String, _ body: [String: Any]) -> [String: Any] {
        ["id": id, "name": body["deviceName"] as? String ?? "Phone", "role": "owner", "createdAt": "t",
         "lastSeenAt": NSNull(), "revokedAt": NSNull()]
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
