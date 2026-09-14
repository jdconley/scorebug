import Foundation
import ScorebugMedia
import XCTest

final class FixtureCameraSourceTests: XCTestCase {
    func testSimulatorSourceProducesExportableRealMediaAndStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ArchiveProfile(width: 640, height: 360, videoBitRate: 1_000_000)
        let writer = try SegmentedArchiveWriter(directory: root.appendingPathComponent("part"), profile: profile)
        let owner = CaptureRecording(source: FixtureCameraSource(profile: profile),
            session: try RecordingSession(sink: SegmentedArchiveSink(writer: writer)))
        try await owner.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while writer.snapshot.acceptedDuration < 3 {
            guard ContinuousClock.now < deadline else { XCTFail("Fixture failed to advance"); owner.cancel(); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let recovered = try await owner.stop()
        let samplesAfterStop = owner.snapshot.writtenSamples
        let exported = try await ArchiveExporter().export(recovered, to: root.appendingPathComponent("movie.mp4"))
        XCTAssertGreaterThanOrEqual(exported.videoFrames, 89)
        XCTAssertGreaterThanOrEqual(exported.audioSamples, 140_000)
        XCTAssertLessThan(exported.duration, 5, "Nonzero fixture origin must not create a blank lead-in")
        XCTAssertEqual(owner.snapshot.writtenSamples, samplesAfterStop)
        XCTAssertEqual(owner.snapshot.state, .finished)
    }
}
