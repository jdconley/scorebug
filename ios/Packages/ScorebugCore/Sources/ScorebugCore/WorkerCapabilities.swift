import Foundation

/// Startup initialization is distinct from sustained decode/encode capacity.
public struct WorkerCapabilitiesResponse: Decodable, Equatable, Sendable {
    public struct Capabilities: Decodable, Equatable, Sendable {
        public let version: Int
        public let outputId, encoder, outputProfile, outputMode, startup, sustainedPerformance: String
    }
    public let workerId, state, serverTime: String
    public let validForMs: Double
    public let capabilities: Capabilities?

    public func permitsStart(worker: String, output: String, requestDuration: Duration) -> Bool {
        guard workerId == worker, state == "fresh", validForMs.isFinite, validForMs > 0, validForMs <= 5000,
              requestDuration >= .zero, requestDuration < .milliseconds(validForMs),
              let capabilities, capabilities.version == 1, capabilities.outputId == output,
              capabilities.startup == "passed", capabilities.sustainedPerformance == "unqualified",
              ["software", "videotoolbox", "nvenc"].contains(capabilities.encoder),
              ["rtmp", "record", "rtmp+record"].contains(capabilities.outputMode),
              ["240p30", "360p30", "540p30", "720p30", "1080p30", "2160p30"].contains(capabilities.outputProfile) else { return false }
        return true
    }
}
