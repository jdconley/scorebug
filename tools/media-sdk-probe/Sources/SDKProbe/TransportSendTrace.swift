import Foundation
import ScorebugStreaming

/// A sealed diagnostic prefix. Unhealthy stop need not join every send callback;
/// an unmatched start never proves that the socket itself is still blocked.
public final class TransportSendTrace: @unchecked Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let publishingGeneration: String
        public let sequence: String
        public let phase: String
        public let byteCount: Int
        public let pendingPacketCount: Int
        public let observedAt: Double
    }
    public struct Snapshot: Codable, Equatable, Sendable {
        public let scope: String
        public let maximumEvents: Int
        public let overflow: Bool
        public let cutoffAt: Double
        public let openAttempts: [String]
        public let rows: [Row]
    }
    private let lock = NSLock()
    private let capacity: Int
    private let now: @Sendable () -> Double
    private var rows: [Row] = []
    private var overflow = false
    private var sealed: Snapshot?

    public convenience init() {
        self.init(capacity: 4096, now: { ProcessInfo.processInfo.systemUptime })
    }
    init(capacity: Int, now: @escaping @Sendable () -> Double) {
        precondition((1...4096).contains(capacity))
        self.capacity = capacity; self.now = now
    }
    public func record(_ value: SRTPublisher.TransportSendObservation) {
        record(Row(publishingGeneration: String(value.publishingGeneration), sequence: String(value.sequence),
            phase: value.phase.rawValue, byteCount: value.byteCount,
            pendingPacketCount: value.pendingPacketCount, observedAt: value.observedAt))
    }
    func record(_ row: Row) {
        lock.withLock {
            guard sealed == nil else { return }
            guard rows.count < capacity else { overflow = true; return }
            rows.append(row)
        }
    }
    public func seal() -> Snapshot {
        lock.withLock {
            if let sealed { return sealed }
            let cutoff = now()
            var open: Set<String> = []
            for row in rows {
                let identity = row.publishingGeneration + ":" + row.sequence
                if row.phase == "started" { open.insert(identity) }
                else if row.phase == "returned" { open.remove(identity) }
            }
            let result = Snapshot(scope: "boundedPrefix", maximumEvents: capacity, overflow: overflow,
                cutoffAt: cutoff, openAttempts: open.sorted(), rows: rows)
            sealed = result
            return result
        }
    }
}
