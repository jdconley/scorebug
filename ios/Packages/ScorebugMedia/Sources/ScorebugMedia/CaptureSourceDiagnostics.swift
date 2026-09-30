import Foundation

public enum CaptureVideoDropReason: String, Codable, Sendable {
    case frameWasLate, outOfBuffers, discontinuity, unknown
}

/// Scalar diagnostics only: no sample buffers, frame pixels or unbounded keys.
public struct CaptureSourceDiagnostics: Codable, Equatable, Sendable {
    public private(set) var videoFrames: UInt64 = 0
    public private(set) var audioBuffers: UInt64 = 0
    public private(set) var frameWasLate: UInt64 = 0
    public private(set) var outOfBuffers: UInt64 = 0
    public private(set) var discontinuity: UInt64 = 0
    public private(set) var unknownDrops: UInt64 = 0
    public var cameraPressureLevel = "unknown"
    public init() {}
    mutating func delivered(video: Bool) {
        if video { videoFrames += 1 } else { audioBuffers += 1 }
    }
    mutating func dropped(_ reason: CaptureVideoDropReason) {
        switch reason {
        case .frameWasLate: frameWasLate += 1
        case .outOfBuffers: outOfBuffers += 1
        case .discontinuity: discontinuity += 1
        case .unknown: unknownDrops += 1
        }
    }
}
