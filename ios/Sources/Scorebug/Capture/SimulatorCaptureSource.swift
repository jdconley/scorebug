#if DEBUG
import AVFoundation
import Foundation
import ScorebugMedia

/// App.swift calls this only in a DEBUG Simulator build. Files are staged in the
/// app's container, never bundled; any requested but invalid setup fails closed.
enum SimulatorCaptureSource {
    static func make(environment: [String: String], supportDirectory: URL, profile: ArchiveProfile = .init()) throws -> any CaptureSource {
        guard let flag = environment["SCOREBUG_TEST_FILE_CAPTURE"] else {
            return FixtureCameraSource(profile: profile, failAfterFrames: Int(environment["SCOREBUG_FIXTURE_FAIL_AFTER"] ?? ""),
                                       motionFlag: environment["SCOREBUG_TEST_MOTION_FIXTURE"])
        }
        guard flag == "1", environment["SCOREBUG_TEST_MOTION_FIXTURE"] == nil,
              environment["SCOREBUG_FIXTURE_FAIL_AFTER"] == nil else { throw ConfigurationError.invalid }
        return FileFixtureCameraSource(url: supportDirectory.appendingPathComponent("Scorebug/QA/input.mov"), profile: profile)
    }
    static func makeSink(directory: URL, profile: ArchiveProfile, environment: [String: String]) throws -> any RecordingArchiveSink {
        guard let fault = environment["SCOREBUG_TEST_RECORDING_FAULT"] else {
            return try RecordingLibrary.defaultSinkFactory(directory, profile)
        }
        guard ["source", "storage", "queue"].contains(fault), environment["SCOREBUG_TEST_FILE_CAPTURE"] == nil else {
            throw ConfigurationError.invalid
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let capacity: (@Sendable () -> Int64?)?
        if fault == "storage" { capacity = { ContinuousClock.now < deadline ? Int64.max : 0 } }
        else { capacity = nil }
        let writer = try SegmentedArchiveWriter(directory: directory, profile: profile, availableBytes: capacity)
        let sink = SegmentedArchiveSink(writer: writer)
        if fault == "queue" { return BlockedFixtureSink(inner: sink, deadline: deadline) }
        return sink
    }
    static func acceptedDuration(_ sink: any RecordingArchiveSink) -> Double? {
        if let sink = sink as? BlockedFixtureSink { return sink.inner.writer.acceptedDuration }
        return (sink as? SegmentedArchiveSink)?.writer.acceptedDuration
    }
    private struct BlockedFixtureSink: RecordingArchiveSink {
        let inner: SegmentedArchiveSink
        let deadline: ContinuousClock.Instant
        func start(at timestamp: CMTime) throws { try inner.start(at: timestamp) }
        func append(_ sample: CapturedMediaSample) throws -> Bool {
            guard ContinuousClock.now < deadline else { return false }
            return try inner.append(sample)
        }
        func finish() async throws -> RecoveredArchive { try await inner.finish() }
        func cancel() { inner.cancel() }
    }
    private enum ConfigurationError: Error { case invalid }
}
#endif
