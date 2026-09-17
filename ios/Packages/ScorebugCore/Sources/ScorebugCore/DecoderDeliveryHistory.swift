import Foundation

/// Bounded transport reconstruction only. Authentication and publication ownership
/// are enforced by WorkerDecoderDeliveryTracker, not by this packet container.
public struct DecoderDeliveryHistory: Sendable {
    public enum Failure: Error { case invalid, incomplete, regression, coverage, overlap, backdated }
    public private(set) var packet: DecoderDeliveryPacket?
    public init() {}
    public mutating func accept(_ next: DecoderDeliveryPacket) throws {
        guard next.isValid else { throw Failure.invalid }
        guard let old = packet else {
            guard next.isFull else { throw Failure.incomplete }; packet = next; return
        }
        guard old.scopeID == next.scopeID, next.sampledAtMs >= old.sampledAtMs,
              next.lastOrdinal >= old.lastOrdinal, next.coverageAtMs >= old.coverageAtMs,
              !old.ended || (next.ended && next.sampledAtMs == old.sampledAtMs && next.lastOrdinal == old.lastOrdinal),
              old.invalidReason == nil || old.invalidReason == next.invalidReason else { throw Failure.regression }
        let base = next.retainedBase
        if base == old.afterOrdinal, next.coverageAtMs != old.coverageAtMs { throw Failure.coverage }
        if base > old.afterOrdinal, base <= old.lastOrdinal,
           next.coverageAtMs != old.arrivals[Int(base - old.afterOrdinal - 1)].atMs { throw Failure.coverage }
        if base > old.lastOrdinal, next.coverageAtMs < old.sampledAtMs { throw Failure.coverage }
        var rows: [Int64: DecoderDeliveryPacket.Arrival] = [:]
        for (i, row) in old.arrivals.enumerated() {
            let ordinal = old.afterOrdinal + Int64(i) + 1
            if ordinal > base { rows[ordinal] = row }
        }
        for (i, row) in next.arrivals.enumerated() {
            let ordinal = next.afterOrdinal + Int64(i) + 1
            if let prior = rows[ordinal], prior != row { throw Failure.overlap }
            if ordinal > old.lastOrdinal, row.atMs < old.sampledAtMs { throw Failure.backdated }
            rows[ordinal] = row
        }
        var result = next; result.afterOrdinal = base; result.arrivals = []
        var ordinal = base
        while ordinal < next.lastOrdinal {
            ordinal += 1
            guard let row = rows[ordinal] else { throw Failure.incomplete }
            result.arrivals.append(row)
        }
        guard result.isFull else { throw Failure.invalid }
        packet = result
    }
    public var snapshot: DecoderDeliverySnapshot? {
        guard let p = packet else { return nil }
        return .init(formatVersion: 1, scopeID: p.scopeID, coverageAgeMs: p.sampledAtMs - p.coverageAtMs,
            lastOrdinal: p.lastOrdinal, arrivals: p.arrivals.enumerated().map { i, row in
                .init(ordinal: p.afterOrdinal + Int64(i) + 1, pts: row.pts, ageMs: p.sampledAtMs - row.atMs)
            }, invalidReason: p.invalidReason, ended: p.ended)
    }
}
