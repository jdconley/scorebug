import Foundation
import ScorebugMedia
import XCTest

final class FixtureCameraSourceTests: XCTestCase {
    func testAudioMarkersHaveSilenceBetweenDistinctTimedBursts() {
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: 0.5), 0)
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: 1.99), 0)
        let firstTime = 1.0 / 48_000
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: firstTime), Int16(0.5 * 32767 * sin(2 * .pi * 1000 * firstTime)))
        let secondTime = 2 + firstTime
        XCTAssertEqual(FixtureCameraSource.markerPCM(at: secondTime), Int16(0.5 * 32767 * sin(2 * .pi * 1020 * secondTime)))
    }

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
