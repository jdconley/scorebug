import CoreMedia

/// Immutable source-to-MPEG-TS mapping. Values are unwrapped 90 kHz ticks;
/// timestamp serialization alone applies the 33-bit wire modulus.
/// This clock does not identify receipt, loss, capacity or a profile transition.
public struct TransportClock: Equatable, Sendable {
    public static let timescale: CMTimeScale = 90_000
    public static let presentationLead: Int64 = 9_000
    public let origin: CMTime

    public init?(origin: CMTime) {
        guard Self.valid(origin) else { return nil }
        self.origin = origin
    }

    /// floor((source - origin) * 90000) + 9000, with exact rational subtraction.
    public func presentationTimestamp(for source: CMTime) -> Int64? {
        guard let delta = deltaTicks(for: source) else { return nil }
        let sum = delta.addingReportingOverflow(Self.presentationLead)
        return sum.overflow ? nil : sum.partialValue
    }

    /// The common clock has no PES decoder lead and shares the same quantization.
    public func clockReference(for source: CMTime) -> UInt64? {
        deltaTicks(for: source).map(UInt64.init)
    }

    private static func valid(_ time: CMTime) -> Bool {
        time.isNumeric && time.timescale > 0 && time.epoch == 0
    }

    // Floor decomposition avoids negating Int64.min. Adjustment is safe: a
    // negative remainder implies scale > 1 and quotient > Int64.min.
    private static func components(_ time: CMTime) -> (whole: Int64, remainder: Int64) {
        let scale = Int64(time.timescale)
        let quotient = time.value / scale
        let remainder = time.value % scale
        return remainder < 0 ? (quotient - 1, remainder + scale) : (quotient, remainder)
    }

    private func deltaTicks(for source: CMTime) -> Int64? {
        guard Self.valid(source) else { return nil }
        let a = Self.components(source), b = Self.components(origin)
        let difference = a.whole.subtractingReportingOverflow(b.whole)
        guard !difference.overflow else { return nil }
        var whole = difference.partialValue
        let sourceScale = Int64(source.timescale), originScale = Int64(origin.timescale)
        // Both products are below denominator <= Int32.max squared < Int64.max.
        let denominator = sourceScale * originScale
        var numerator = a.remainder * originScale - b.remainder * sourceScale
        if numerator < 0 {
            let borrowed = whole.subtractingReportingOverflow(1)
            guard !borrowed.overflow else { return nil }
            whole = borrowed.partialValue
            numerator += denominator
        }
        guard whole >= 0 else { return nil }
        let seconds = whole.multipliedReportingOverflow(by: Int64(Self.timescale))
        guard !seconds.overflow else { return nil }
        // 0 <= numerator < denominator, so this full-width quotient is < 90000
        // and cannot overflow dividingFullWidth's UInt64 result.
        let product = UInt64(numerator).multipliedFullWidth(by: UInt64(Self.timescale))
        let fraction = UInt64(denominator).dividingFullWidth(product).quotient
        let ticks = seconds.partialValue.addingReportingOverflow(Int64(fraction))
        return ticks.overflow ? nil : ticks.partialValue
    }
}
