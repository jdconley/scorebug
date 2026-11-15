import Foundation

/// Bounded structural preflight. Foundation parses scalar strings and the final
/// object; this pass supplies duplicate-key/depth checks before typed decoding.
struct WatchRelayJSON {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw WatchRelayCodecError.invalidMessage }
    }

    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private mutating func value(depth: Int) throws {
        whitespace()
        guard depth < 12, index < bytes.count else { throw WatchRelayCodecError.invalidMessage }
        switch bytes[index] {
        case 123:
            index += 1
            var keys = Set<String>()
            if consume(125) { return }
            repeat {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted, consume(58) else { throw WatchRelayCodecError.invalidMessage }
                try value(depth: depth + 1)
                if consume(125) { return }
                guard consume(44) else { throw WatchRelayCodecError.invalidMessage }
            } while true
        case 91:
            index += 1
            if consume(93) { return }
            repeat {
                try value(depth: depth + 1)
                if consume(93) { return }
                guard consume(44) else { throw WatchRelayCodecError.invalidMessage }
            } while true
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            let token = Array(bytes[start..<index])
            if token == Array("true".utf8) || token == Array("false".utf8) || token == Array("null".utf8) { return }
            // Every numeric field in this wire version is an integer. Reject
            // decimal/exponent lexemes before Foundation can round a fraction.
            let digits = token.first == 45 ? Array(token.dropFirst()) : token
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                  digits.count == 1 || digits.first != 48,
                  let number = Int64(String(decoding: token, as: UTF8.self)),
                  (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else {
                throw WatchRelayCodecError.invalidMessage
            }
        }
    }
    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw WatchRelayCodecError.invalidMessage }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                guard let string = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else {
                    throw WatchRelayCodecError.invalidMessage
                }
                return string
            }
            if byte == 92 {
                guard index < bytes.count else { throw WatchRelayCodecError.invalidMessage }
                index += 1
            }
        }
        throw WatchRelayCodecError.invalidMessage
    }
}
