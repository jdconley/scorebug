import CoreFoundation
import Foundation

public enum WatchRelayCodecError: Error, Equatable, Sendable { case invalidMessage }

/// A strict scoring-only wire boundary. Callers must separately authorize the
/// entire scope against their durable pairing and authenticate with the server.
/// Use these codec methods at the boundary; plain Codable is not validation.
public enum WatchRelayCodec {
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumReplyBytes = 32 * 1024
    // Match models use native Int, which is 32-bit on arm64_32 Watch targets.
    // Reject values outside that representation rather than truncating them.
    private static let safeInteger = Int(clamping: Int64(9_007_199_254_740_991))

    public static func validateScope(_ value: WatchRelayScope) throws {
        do {
            guard value.endpoint.utf8.count <= 4096,
                  try ScoringEndpoint(value.endpoint).canonicalAddress == value.endpoint,
                  identifier(value.gameId), uuid(value.watchDeviceId), uuid(value.pairingId) else { throw WatchRelayCodecError.invalidMessage }
        } catch { throw WatchRelayCodecError.invalidMessage }
    }

    public static func encodeRequest(_ value: WatchRelayRequest) throws -> Data {
        do {
            let data = try encode(value)
            _ = try decodeRequest(data)
            return data
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func decodeRequest(_ data: Data) throws -> WatchRelayRequest {
        do {
            let object = try object(data, maximum: maximumRequestBytes)
            try keys(object, ["version", "requestId", "scope", "credential", "operation"])
            try version(object)
            try scopeObject(object["scope"])
            let credential = try dictionary(object["credential"])
            try keys(credential, ["gameId", "deviceId", "role", "token"])
            guard identifier(try string(credential["gameId"])), uuid(try string(credential["deviceId"])),
                  try string(credential["role"]) == "score",
                  let token = credential["token"] as? String, token.utf8.count == 43, identifier(token) else { throw WatchRelayCodecError.invalidMessage }
            let operation = try dictionary(object["operation"])
            switch try string(operation["type"]) {
            case "snapshot": try keys(operation, ["type"])
            case "execute": try keys(operation, ["type", "command"]); try commandObject(operation["command"])
            case "receipt":
                try keys(operation, ["type", "commandId"])
                guard identifier(try string(operation["commandId"])) else { throw WatchRelayCodecError.invalidMessage }
            default: throw WatchRelayCodecError.invalidMessage
            }
            let value = try JSONDecoder().decode(WatchRelayRequest.self, from: data)
            guard value.credential.gameId == value.scope.gameId,
                  value.credential.deviceId == value.scope.watchDeviceId else { throw WatchRelayCodecError.invalidMessage }
            if case .execute(let command) = value.operation {
                guard command.gameId == value.scope.gameId, command.deviceId == value.scope.watchDeviceId else { throw WatchRelayCodecError.invalidMessage }
            }
            return value
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func encodeReply(_ value: WatchRelayReply, for request: WatchRelayRequest) throws -> Data {
        do {
            let data = try encode(value)
            _ = try decodeReply(data, for: request)
            return data
        } catch { throw WatchRelayCodecError.invalidMessage }
    }
    public static func decodeReply(_ data: Data, for request: WatchRelayRequest) throws -> WatchRelayReply {
        do {
            _ = try encodeRequest(request)
            let object = try object(data, maximum: maximumReplyBytes)
            try keys(object, ["version", "requestId", "scope", "operation", "result"])
            try version(object)
            try scopeObject(object["scope"])
            let result = try dictionary(object["result"])
            switch try string(result["type"]) {
            case "snapshot":
                try keys(result, ["type", "value"])
                let value = try dictionary(result["value"])
                try keys(value, ["snapshot", "serverTime"])
                try snapshotObject(value["snapshot"])
                try date(value["serverTime"])
            case "outcome", "receipt_found":
                try keys(result, ["type", "value"]); try outcomeObject(result["value"])
            case "receipt_absent": try keys(result, ["type"])
            case "failure": try keys(result, ["type", "error"]); try failureObject(result["error"])
            default: throw WatchRelayCodecError.invalidMessage
            }
            let value = try JSONDecoder().decode(WatchRelayReply.self, from: data)
            guard value.requestId == request.requestId, value.scope == request.scope,
                  value.operation == request.operation.kind else { throw WatchRelayCodecError.invalidMessage }
            switch (request.operation, value.result) {
            case (.snapshot, .snapshot(let response)):
                guard response.snapshot.id == request.scope.gameId else { throw WatchRelayCodecError.invalidMessage }
            case (.execute(let command), .outcome(let outcome)):
                try correlate(outcome, commandId: command.commandId, gameId: request.scope.gameId)
            case (.receipt(let commandId), .receiptFound(let outcome)):
                try correlate(outcome, commandId: commandId, gameId: request.scope.gameId)
            case (.receipt, .receiptAbsent), (_, .failure): break
            default: throw WatchRelayCodecError.invalidMessage
            }
            return value
        } catch { throw WatchRelayCodecError.invalidMessage }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func object(_ data: Data, maximum: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximum else { throw WatchRelayCodecError.invalidMessage }
        var preflight = WatchRelayJSON(data)
        try preflight.validate()
        return try dictionary(JSONSerialization.jsonObject(with: data))
    }
    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw WatchRelayCodecError.invalidMessage }
        return value
    }
    private static func keys(_ value: [String: Any], _ required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(value.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw WatchRelayCodecError.invalidMessage }
    }
    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw WatchRelayCodecError.invalidMessage }
        return value
    }
    private static func integer(_ value: Any?, min: Int = 0, max: Int = safeInteger) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(min), number.doubleValue <= Double(max) else { throw WatchRelayCodecError.invalidMessage }
        return number.intValue
    }
    private static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw WatchRelayCodecError.invalidMessage }
        return number.boolValue
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func uuid(_ value: String) -> Bool { value.utf8.count == 36 && UUID(uuidString: value) != nil }
    private static func version(_ value: [String: Any]) throws {
        guard try integer(value["version"]) == 1, uuid(try string(value["requestId"])) else { throw WatchRelayCodecError.invalidMessage }
    }
    private static func scopeObject(_ input: Any?) throws {
        let value = try dictionary(input)
        try keys(value, ["endpoint", "gameId", "watchDeviceId", "pairingId"])
        try validateScope(WatchRelayScope(endpoint: string(value["endpoint"]), gameId: string(value["gameId"]), watchDeviceId: string(value["watchDeviceId"]), pairingId: string(value["pairingId"])))
    }
    private static func oneOf(_ value: Any?, _ options: Set<String>) throws {
        guard options.contains(try string(value)) else { throw WatchRelayCodecError.invalidMessage }
    }
    private static func date(_ input: Any?) throws {
        let value = try string(input)
        guard value.utf8.count <= 128, value.last == "Z",
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$"#, options: .regularExpression) != nil else { throw WatchRelayCodecError.invalidMessage }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let parsed = formatter.date(from: value) else { throw WatchRelayCodecError.invalidMessage }
        // Some Foundation parsers normalize invalid calendar dates. Compare the
        // integral UTC fields so an invalid day cannot silently become another.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        let bytes = Array(value.utf8)
        let fields = [(0, 4), (5, 7), (8, 10), (11, 13), (14, 16), (17, 19)].map { Int(String(decoding: bytes[$0.0..<$0.1], as: UTF8.self)) }
        guard fields == [components.year, components.month, components.day, components.hour, components.minute, components.second] else { throw WatchRelayCodecError.invalidMessage }
    }
    // ECMAScript TrimString whitespace/line terminators, including BOM (FEFF),
    // excluding Foundation-only whitespace such as NEXT LINE (0085).
    private static let ecmaWhitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    private static func boundedText(_ input: Any?, max: Int, trim: Bool = false) throws {
        let original = try string(input)
        let value = trim ? original.trimmingCharacters(in: ecmaWhitespace) : original
        guard !value.isEmpty, value.utf16.count <= max else { throw WatchRelayCodecError.invalidMessage }
    }
    private static func nullableText(_ input: Any?, max: Int) throws {
        if input is NSNull { return }
        try boundedText(input, max: max)
    }
    private static func commandObject(_ input: Any?) throws {
        let value = try dictionary(input)
        try keys(value, ["commandId", "gameId", "deviceId", "expectedRevision", "scorerEpoch", "issuedAt", "operation"])
        for key in ["commandId", "gameId", "deviceId"] {
            guard identifier(try string(value[key])) else { throw WatchRelayCodecError.invalidMessage }
        }
        _ = try integer(value["expectedRevision"]); _ = try integer(value["scorerEpoch"], min: 1)
        try date(value["issuedAt"])
        let operation = try dictionary(value["operation"])
        switch try string(operation["type"]) {
        case "award_point": try keys(operation, ["type", "side"]); try oneOf(operation["side"], ["home", "away"])
        case "undo", "take_over": try keys(operation, ["type"])
        case "end_match": try keys(operation, ["type", "reason"]); try boundedText(operation["reason"], max: 500, trim: true)
        case "end_set":
            try keys(operation, ["type"], optional: ["winner", "overrideReason"])
            if let winner = operation["winner"] { try oneOf(winner, ["home", "away"]) }
            if let reason = operation["overrideReason"] { try boundedText(reason, max: 500, trim: true) }
        default: throw WatchRelayCodecError.invalidMessage
        }
    }
    private static func snapshotObject(_ input: Any?) throws {
        let value = try dictionary(input)
        try keys(value, ["id", "createdAt", "revision", "teams", "rules", "score", "completedSets", "status", "endReason", "canUndo", "scorer", "broadcast"])
        guard identifier(try string(value["id"])) else { throw WatchRelayCodecError.invalidMessage }
        try date(value["createdAt"]); _ = try integer(value["revision"])
        let teams = try dictionary(value["teams"]); try keys(teams, ["home", "away"])
        for side in ["home", "away"] {
            let team = try dictionary(teams[side]); try keys(team, ["name", "shortName", "color"])
            try boundedText(team["name"], max: 80); try boundedText(team["shortName"], max: 8)
            let color = try string(team["color"])
            guard color.utf8.count == 7, color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else { throw WatchRelayCodecError.invalidMessage }
        }
        let rules = try dictionary(value["rules"])
        try keys(rules, ["bestOf", "pointsToWin", "decidingPointsToWin", "winBy", "pointCap"])
        let bestOf = try integer(rules["bestOf"])
        guard [3, 5].contains(bestOf) else { throw WatchRelayCodecError.invalidMessage }
        let target = try integer(rules["pointsToWin"], min: 1, max: 99)
        let deciding = try integer(rules["decidingPointsToWin"], min: 1, max: 99)
        _ = try integer(rules["winBy"], min: 1, max: 10)
        if !(rules["pointCap"] is NSNull) { _ = try integer(rules["pointCap"], min: max(target, deciding), max: 199) }
        let score = try dictionary(value["score"])
        try keys(score, ["home", "away", "set", "homeSets", "awaySets"])
        _ = try integer(score["home"]); _ = try integer(score["away"])
        _ = try integer(score["set"], min: 1, max: bestOf)
        _ = try integer(score["homeSets"], max: (bestOf + 1) / 2); _ = try integer(score["awaySets"], max: (bestOf + 1) / 2)
        guard let sets = value["completedSets"] as? [Any], sets.count <= bestOf else { throw WatchRelayCodecError.invalidMessage }
        for element in sets {
            let set = try dictionary(element); try keys(set, ["set", "home", "away", "winner", "overrideReason"])
            _ = try integer(set["set"], min: 1, max: bestOf); _ = try integer(set["home"]); _ = try integer(set["away"])
            try oneOf(set["winner"], ["home", "away"]); try nullableText(set["overrideReason"], max: 500)
        }
        try oneOf(value["status"], ["active", "ended"]); try nullableText(value["endReason"], max: 500)
        _ = try boolean(value["canUndo"])
        let scorer = try dictionary(value["scorer"]); try keys(scorer, ["deviceId", "epoch"])
        guard identifier(try string(scorer["deviceId"])) else { throw WatchRelayCodecError.invalidMessage }
        _ = try integer(scorer["epoch"], min: 1)
        let broadcast = try dictionary(value["broadcast"]); try keys(broadcast, ["desired", "generation"])
        try oneOf(broadcast["desired"], ["stopped", "running"]); _ = try integer(broadcast["generation"])
    }
    private static func outcomeObject(_ input: Any?) throws {
        let value = try dictionary(input)
        try keys(value, ["commandId", "accepted", "error", "snapshot"])
        guard identifier(try string(value["commandId"])) else { throw WatchRelayCodecError.invalidMessage }
        let accepted = try boolean(value["accepted"])
        if accepted {
            guard value["error"] is NSNull else { throw WatchRelayCodecError.invalidMessage }
        } else {
            guard identifier(try string(value["error"])) else { throw WatchRelayCodecError.invalidMessage }
        }
        try snapshotObject(value["snapshot"])
    }
    private static func failureObject(_ input: Any?) throws {
        let value = try dictionary(input)
        switch try string(value["type"]) {
        case "http":
            try keys(value, ["type", "status", "code"]); _ = try integer(value["status"], min: 100, max: 599)
            if !(value["code"] is NSNull) {
                guard identifier(try string(value["code"])) else { throw WatchRelayCodecError.invalidMessage }
            }
        case "unauthorized", "forbidden", "invalidResponse", "invalidRequest", "scopeMismatch", "unavailable", "cancelled", "busy": try keys(value, ["type"])
        default: throw WatchRelayCodecError.invalidMessage
        }
    }
    private static func correlate(_ outcome: CommandOutcome, commandId: String, gameId: String) throws {
        guard outcome.commandId == commandId, outcome.snapshot.id == gameId else { throw WatchRelayCodecError.invalidMessage }
    }
}
