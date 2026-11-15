#if DEBUG
import Foundation

/// Bounded, recording-scoped observations from the joined file-source pump.
enum FileFixtureDiagnostics {
    static func data(recordingID: String, statistics: FileFixtureStatistics) throws -> Data {
        guard !recordingID.isEmpty, statistics.closed else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Export(recordingID: recordingID, statistics: Counters(statistics)))
    }

    private struct Export: Encodable {
        let formatVersion = 1
        let recordingID: String
        let statistics: Counters
    }

    private struct Counters: Encodable {
        let videoFrames, audioSamples, audioBuffers, readCalls: String
        let totalReadSeconds, maximumReadSeconds, maximumSourceLagSeconds: Double
        let firstVideoDeliverySeconds, lastVideoDeliverySeconds: Double?
        let closed: Bool
        init(_ value: FileFixtureStatistics) {
            videoFrames = String(value.videoFrames)
            audioSamples = String(value.audioSamples)
            audioBuffers = String(value.audioBuffers)
            readCalls = String(value.readCalls)
            totalReadSeconds = value.totalReadSeconds
            maximumReadSeconds = value.maximumReadSeconds
            maximumSourceLagSeconds = value.maximumSourceLagSeconds
            firstVideoDeliverySeconds = value.firstVideoDeliverySeconds
            lastVideoDeliverySeconds = value.lastVideoDeliverySeconds
            closed = value.closed
        }
    }

    #if targetEnvironment(simulator)
    static func writeClosed(recordingID: String, statistics: FileFixtureStatistics) async throws {
        try await Task.detached(priority: .utility) {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Scorebug/QA", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data(recordingID: recordingID, statistics: statistics)
                .write(to: directory.appendingPathComponent("file-source.json"), options: .atomic)
        }.value
    }
    #endif
}
#endif
