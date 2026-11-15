import Foundation

/// Wire-shaped arrival data. It needs authenticated publication/worker binding and
/// a conservative sample-age bound before it can support native deadline checks.
public struct DecoderDeliverySnapshot: Codable, Equatable, Sendable {
    public struct Arrival: Codable, Equatable, Sendable {
        public var ordinal: Int64
        public var pts: Int64
        public var ageMs: Double
        public init(ordinal: Int64, pts: Int64, ageMs: Double) {
            self.ordinal = ordinal; self.pts = pts; self.ageMs = ageMs
        }
    }
    public var formatVersion: Int
    public var scopeID: String
    public var coverageAgeMs: Double
    public var lastOrdinal: Int64
    public var arrivals: [Arrival]
    public var invalidReason: String?
    public var ended: Bool
    public init(formatVersion: Int, scopeID: String, coverageAgeMs: Double, lastOrdinal: Int64,
                arrivals: [Arrival], invalidReason: String?, ended: Bool) {
        self.formatVersion = formatVersion; self.scopeID = scopeID; self.coverageAgeMs = coverageAgeMs
        self.lastOrdinal = lastOrdinal; self.arrivals = arrivals; self.invalidReason = invalidReason; self.ended = ended
    }
}

/// A captured source frame already projected into the bound decoder PTS domain.
/// The adapter must prove capture-window completeness and configuration coverage.
public struct DeliveryDeadlineFrame: Equatable, Sendable {
    public let pts: Int64
    public let capturedAt: Double
    public init(pts: Int64, capturedAt: Double) { self.pts = pts; self.capturedAt = capturedAt }
}

public struct DeliveryDeadlineResult: Equatable, Sendable {
    public let expectedFrames: Int
    public let onTimeFrames: Int
    public let lateFrames: Int
    public let missingFrames: Int
    public let uncertainFrames: Int
    public let duration: Double
    public var knownFailureFrames: Int { lateFrames + missingFrames }
    public var knownFailureFraction: Double { Double(knownFailureFrames) / Double(expectedFrames) }
    public var fullyClassified: Bool { uncertainFrames == 0 }
    public var onTimeFPS: Double? { fullyClassified ? Double(onTimeFrames) / duration : nil }
    public var failureFraction: Double? { fullyClassified ? knownFailureFraction : nil }
}
