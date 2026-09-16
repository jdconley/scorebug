import Foundation

/// Versioned payload in valid null TS packets. Observe before demultiplexing;
/// this identifier is attribution, not authentication or receiver capacity.
enum SRTProbeMessage {
    static func encode(id: UUID, generation: UInt64, sequence: UInt64, bitRate: Int) -> Data {
        var prefix = Array("SBUGPRB1".utf8)
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { prefix.append(contentsOf: $0) }
        for value in [generation, sequence] {
            var network = value.bigEndian
            withUnsafeBytes(of: &network) { prefix.append(contentsOf: $0) }
        }
        var rate = UInt32(bitRate).bigEndian
        withUnsafeBytes(of: &rate) { prefix.append(contentsOf: $0) }
        var bytes = [UInt8](repeating: 0xff, count: 1316)
        for part in 0..<7 {
            let at = part * 188
            bytes.replaceSubrange(at..<at + 4, with: [0x47, 0x1f, 0xff, 0x10])
            bytes.replaceSubrange(at + 4..<at + 48, with: prefix)
            bytes[at + 48] = UInt8(part)
        }
        return Data(bytes)
    }
}
