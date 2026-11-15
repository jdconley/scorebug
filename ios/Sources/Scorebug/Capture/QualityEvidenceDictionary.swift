import Foundation
import CoreFoundation

/// Lossless scalar-history interning on the quality actor, never capture callbacks.
/// The aggregate encoded-entry/row budget leaves 1 MiB for JSON envelope overhead.
@MainActor final class QualityEvidenceDictionary {
    private enum Failure: Error { case invalid, limit }
    private final class Table {
        var entries: [[String: Any]] = []
        var keys: [Data] = []
        var indexes: [Data: Int] = [:]
        func rollback(to count: Int) {
            while entries.count > count {
                indexes.removeValue(forKey: keys.removeLast())
                entries.removeLast()
            }
        }
    }
    private let kinds = ["thermal", "transport", "queue"]
    private let tables = [Table(), Table(), Table()]
    private let maximumBytes: Int
    private var bytes = 0, rowCount = 0
    private(set) var isOverflow = false

    init(maximumBytes: Int = 7 * 1024 * 1024) {
        precondition((1...7 * 1024 * 1024).contains(maximumBytes))
        self.maximumBytes = maximumBytes
    }
    var dictionary: [String: Any] {
        ["formatVersion": 1, "thermal": tables[0].entries,
         "transport": tables[1].entries, "queue": tables[2].entries]
    }
    private func reserve(_ count: Int) throws {
        guard count <= maximumBytes - bytes else { throw Failure.limit }
        bytes += count
    }
    private func intern(_ entry: [String: Any], table: Table) throws -> Int {
        guard entry.count <= 32 else { throw Failure.invalid }
        var normalized: [String: Any] = [:]
        for (key, value) in entry {
            guard key.utf16.count <= 128 else { throw Failure.invalid }
            if let string = value as? String {
                guard string.utf16.count <= 512 else { throw Failure.invalid }
                normalized[key] = String(decoding: string.utf8, as: UTF8.self)
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { normalized[key] = number.boolValue }
                else {
                    let numeric = number.doubleValue
                    guard numeric.isFinite, abs(numeric) <= 9_007_199_254_740_991 else { throw Failure.invalid }
                    normalized[key] = numeric == 0 ? 0.0 : numeric
                }
            } else if value is NSNull { normalized[key] = NSNull() }
            else { throw Failure.invalid }
        }
        let key = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        if let index = table.indexes[key] { return index }
        guard table.entries.count < 65536 else { throw Failure.limit }
        try reserve(key.count + 1)
        let index = table.entries.count
        table.entries.append(normalized); table.keys.append(key); table.indexes[key] = index
        return index
    }
    /// Failure rolls back the incomplete row and permanently withdraws evidence
    /// export eligibility. Previously returned value-semantic checkpoints survive.
    func encode(_ row: [String: Any]) -> [String: Any]? {
        guard !isOverflow else { return nil }
        let counts = tables.map { $0.entries.count }, previousBytes = bytes
        do {
            guard rowCount < 512 else { throw Failure.limit }
            var encoded = row
            if row["evidence"] != nil {
                guard var evidence = row["evidence"] as? [String: Any] else { throw Failure.invalid }
                for (index, kind) in kinds.enumerated() {
                    if kind == "queue", evidence[kind] is NSNull { continue }
                    guard var history = evidence[kind] as? [String: Any] else { throw Failure.invalid }
                    let field = kind == "queue" ? "states" : "samples"
                    let rangeKey = kind == "queue" ? "stateRanges" : "sampleRanges"
                    let countKey = kind == "queue" ? "stateCount" : "sampleCount"
                    guard history[rangeKey] == nil, history[countKey] == nil,
                          let values = history[field] as? [[String: Any]],
                          values.count <= (kind == "queue" ? 4096 : 64) else { throw Failure.invalid }
                    var ranges: [[Int]] = []
                    for value in values {
                        let reference = try intern(value, table: tables[index])
                        if let last = ranges.last, last[0] + last[1] == reference {
                            ranges[ranges.count - 1][1] += 1
                        } else { ranges.append([reference, 1]) }
                    }
                    history.removeValue(forKey: field)
                    history[rangeKey] = ranges; history[countKey] = values.count
                    evidence[kind] = history
                }
                encoded["evidence"] = evidence
            }
            let data = try JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys])
            try reserve(data.count + 1)
            rowCount += 1
            return encoded
        } catch {
            for (index, table) in tables.enumerated() { table.rollback(to: counts[index]) }
            bytes = previousBytes; isOverflow = true
            return nil
        }
    }
}
