import AVFoundation
import Foundation
import ScorebugMedia
import XCTest

final class FixtureMotionPatternTests: XCTestCase {
    func testMotionPreservesBarcodeAndStaticRegionsInStridePaddedFrames() async throws {
        let profile = ArchiveProfile(width: 322, height: 242)
        let baseline = try await capture(profile: profile, flag: nil, frames: 10)
        let motion = try await capture(profile: profile, flag: "1", frames: 10)
        let repeated = try await capture(profile: profile, flag: "1", frames: 10)
        XCTAssertEqual(motion.count, 20)
        let videos = motion.filter { $0.kind == .video }
        XCTAssertEqual(Set(videos.map { ObjectIdentifier($0.sample.imageBuffer!) }).count, 10)
        for (index, entry) in motion.enumerated() {
            XCTAssertEqual(entry.kind, index.isMultiple(of: 2) ? .video : .audio)
            let pts = CMTime(value: 7_395, timescale: 60) + CMTime(value: Int64(index / 2), timescale: 30)
            XCTAssertEqual(CMTimeCompare(entry.sample.presentationTimeStamp, pts), 0)
            XCTAssertEqual(entry.bytes, repeated[index].bytes, "Fixed seed reproduces each complete frame/sample")
            if entry.kind == .audio {
                XCTAssertEqual(entry.sample.numSamples, 1600)
                XCTAssertEqual(entry.bytes, baseline[index].bytes)
                continue
            }
            let pixel = try XCTUnwrap(entry.sample.imageBuffer)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixel), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(CMTimeCompare(entry.sample.duration, CMTime(value: 1, timescale: 30)), 0)
            XCTAssertEqual(try packedBytes(entry.sample), entry.bytes, "Published buffers remain immutable after later callbacks")
            XCTAssertTrue(entry.bytes.prefix(profile.width * profile.height).allSatisfy { (16...235).contains($0) })
            XCTAssertTrue(entry.bytes.suffix(profile.width * profile.height / 2).allSatisfy { (16...240).contains($0) })
            assertStaticRegions(entry.bytes, equalTo: baseline[index].bytes, profile: profile)
            let middle = profile.width * (profile.height / 3)..<profile.width * (profile.height * 5 / 6)
            XCTAssertNotEqual(entry.bytes[middle], baseline[index].bytes[middle])
        }
        let middle = profile.width * (profile.height / 3)..<profile.width * (profile.height * 5 / 6)
        XCTAssertNotEqual(videos[0].bytes[middle], videos[1].bytes[middle])
        XCTAssertEqual(videos[0].bytes[middle], videos[8].bytes[middle], "Eight prepared textures repeat without per-frame noise")
    }

    func test1080MotionLeavesEntireScoreComparisonCropAndBarcodeUnchanged() async throws {
        let profile = ArchiveProfile()
        let baseline = try await capture(profile: profile, flag: "", frames: 2)
        let motion = try await capture(profile: profile, flag: "1", frames: 2)
        for index in [0, 2] {
            assertStaticRegions(motion[index].bytes, equalTo: baseline[index].bytes, profile: profile)
            for row in 930..<1050 {
                let crop = row * profile.width..<row * profile.width + 750
                XCTAssertEqual(motion[index].bytes[crop], baseline[index].bytes[crop])
            }
            for row in 465..<525 {
                let crop = profile.width * profile.height + row * profile.width..<profile.width * profile.height + row * profile.width + 750
                XCTAssertEqual(motion[index].bytes[crop], baseline[index].bytes[crop])
            }
            let middle = 360 * profile.width..<900 * profile.width
            let changed = zip(motion[index].bytes[middle], baseline[index].bytes[middle]).filter { $0 != $1 }.count
            XCTAssertGreaterThan(changed, middle.count * 9 / 10)
        }
    }

    func testDefaultFixtureRetainsExactBarcodeBackgroundAndMovingBlock() async throws {
        let profile = ArchiveProfile(width: 320, height: 240)
        let samples = try await capture(profile: profile, flag: nil, frames: 3)
        for frame in 0..<3 {
            let bytes = samples[frame * 2].bytes
            for row in 0..<profile.height {
                for column in 0..<profile.width {
                    let expected: UInt8
                    if row < profile.height / 3 { expected = (frame >> (column / 20)) & 1 == 1 ? 220 : 70 }
                    else if (120..<160).contains(row) && (frame * 8..<frame * 8 + 40).contains(column) { expected = 230 }
                    else { expected = 32 }
                    if bytes[row * profile.width + column] != expected { XCTFail("Default pixel changed at \(column),\(row)"); return }
                }
            }
            XCTAssertTrue(bytes.suffix(profile.width * profile.height / 2).allSatisfy { $0 == 128 })
        }
    }

    func testMalformedMotionFlagFailsPrepareAndCannotStart() async throws {
        for flag in ["0", "true", "01", " 1", "1 ", "\n1"] {
            let source = FixtureCameraSource(profile: ArchiveProfile(width: 320, height: 240), motionFlag: flag)
            do {
                _ = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { _ in XCTFail("Unexpected sample") }, event: { _ in XCTFail("Unexpected event") }))
                XCTFail("Invalid motion flag accepted")
            } catch {}
            do { try await source.start(); XCTFail("Unprepared motion source started") } catch {}
            await source.stop()
        }
    }

    func testOversizedMotionProfileFailsWithoutChangingArchiveProfileValidation() async throws {
        let profile = ArchiveProfile(width: 7680, height: 4320)
        XCTAssertNoThrow(try profile.validate())
        let callbacks = CaptureSourceCallbacks(sample: { _ in }, event: { _ in })
        let motion = FixtureCameraSource(profile: profile, motionFlag: "1")
        do { _ = try await motion.prepare(callbacks: callbacks); XCTFail("Oversized motion textures accepted") } catch {}
        let baseline = FixtureCameraSource(profile: profile)
        _ = try await baseline.prepare(callbacks: callbacks)
        await baseline.stop()
        await motion.stop()
    }

    func testPackedTextureBudgetChecksBeforeAllocationAndSeedChangesPixels() throws {
        XCTAssertEqual(FixtureMotionPattern.textureCount, 8)
        XCTAssertEqual(FixtureMotionPattern.maximumRetainedBytes, 32 * 1024 * 1024)
        XCTAssertEqual(try FixtureMotionPattern.retainedByteCount(profile: ArchiveProfile()), 24_883_200)
        XCTAssertEqual(try FixtureMotionPattern.retainedByteCount(profile: ArchiveProfile(width: 2048, height: 1364)), 33_521_664)
        for profile in [ArchiveProfile(width: 2048, height: 1366), ArchiveProfile(width: Int.max, height: 1080)] {
            XCTAssertThrowsError(try FixtureMotionPattern.retainedByteCount(profile: profile))
        }
        let profile = ArchiveProfile(width: 320, height: 240)
        let a = try FixtureMotionPattern(profile: profile, seed: 7)
        let b = try FixtureMotionPattern(profile: profile, seed: 7)
        let c = try FixtureMotionPattern(profile: profile, seed: 8)
        XCTAssertEqual(a.retainedBytes, 921_600)
        func pixels(_ pattern: FixtureMotionPattern) throws -> Data {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, profile.width, profile.height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 0, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
            try pattern.copyMiddle(into: buffer, frame: 0)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            return Data(bytes: base, count: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * profile.height)
        }
        XCTAssertEqual(try pixels(a), try pixels(b))
        XCTAssertNotEqual(try pixels(a), try pixels(c))
    }

    private func capture(profile: ArchiveProfile, flag: String?, frames: Int) async throws -> [MotionLedger.Entry] {
        let source = FixtureCameraSource(profile: profile, failAfterFrames: frames, motionFlag: flag)
        let ledger = MotionLedger()
        let stopped = expectation(description: "fixture completed selected frame pairs")
        _ = try await source.prepare(callbacks: CaptureSourceCallbacks(sample: { ledger.record($0) }, event: { _ in stopped.fulfill() }))
        try await source.start()
        await fulfillment(of: [stopped], timeout: 10)
        await source.stop()
        let result = ledger.entries
        await source.stop()
        do { try await source.start(); XCTFail("Stopped source restarted") } catch {}
        XCTAssertEqual(ledger.entries.count, result.count)
        XCTAssertEqual(result.count, frames * 2)
        return result
    }

    private func assertStaticRegions(_ actual: Data, equalTo expected: Data, profile: ArchiveProfile,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for plane in 0..<2 {
            let lower = plane == 0 ? profile.height / 3 : (profile.height / 3 + 1) / 2
            let upper = plane == 0 ? profile.height * 5 / 6 : (profile.height * 5 / 6) / 2
            let rows = plane == 0 ? profile.height : profile.height / 2
            let offset = plane == 0 ? 0 : profile.width * profile.height
            for row in 0..<rows where row < lower || row >= upper {
                let bounds = offset + row * profile.width..<offset + (row + 1) * profile.width
                XCTAssertEqual(actual[bounds], expected[bounds], file: file, line: line)
            }
        }
    }
}

private final class MotionLedger: @unchecked Sendable {
    struct Entry { let kind: CapturedMediaSample.Kind; let sample: CMSampleBuffer; let bytes: Data }
    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] { lock.withLock { recorded } }
    func record(_ sample: CapturedMediaSample) {
        do {
            let bytes = try packedBytes(sample.sampleBuffer)
            lock.withLock { recorded.append(Entry(kind: sample.kind, sample: sample.sampleBuffer, bytes: bytes)) }
        } catch { XCTFail("Could not read emitted sample: \(error)") }
    }
}

private func packedBytes(_ sample: CMSampleBuffer) throws -> Data {
    if let pixel = sample.imageBuffer {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        var result = Data()
        for plane in 0..<2 {
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, plane))
            let width = CVPixelBufferGetWidth(pixel)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(pixel, plane) {
                result.append(address.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width)
            }
        }
        return result
    }
    let block = try XCTUnwrap(sample.dataBuffer)
    let count = CMBlockBufferGetDataLength(block)
    var result = Data(count: count)
    let status = result.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    return result
}
