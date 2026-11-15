import CoreMedia

/// The native muxer's chosen clock for one publishing generation.
/// Describes floor((source - sourceOrigin) * 90000) + 9000 before wire modulo.
/// Projection arithmetic belongs to the SDK; this value only records its mapping.
public struct PublishingTransportClock: Equatable, Sendable {
    public let sourceOrigin: CMTime
    public let publishingGeneration: UInt64
    public static let timescale: CMTimeScale = 90_000
    public static let presentationLead: Int64 = 9_000
    public static let wireModulus: Int64 = 8_589_934_592
    public init?(sourceOrigin: CMTime, publishingGeneration: UInt64) {
        guard sourceOrigin.isNumeric, sourceOrigin.timescale > 0, sourceOrigin.epoch == 0,
              publishingGeneration > 0 else { return nil }
        self.sourceOrigin = sourceOrigin
        self.publishingGeneration = publishingGeneration
    }
}
