#if DEBUG
import CoreVideo
import Foundation
import ScorebugMedia

/// Synthetic encoding workload, prepared before the capture clock starts. Eight
/// immutable tightly packed NV12 frames retain at most 32 MiB in total. Only the
/// middle vertical band is copied, preserving identity and scoring backgrounds.
struct FixtureMotionPattern: Sendable {
    static let textureCount = 8
    static let maximumRetainedBytes = 32 * 1024 * 1024
    static let seed: UInt64 = 0x5343_4f52_4542_5547
    enum Failure: Error { case flag, capacity, buffer }
    enum Pattern: Sendable { case pixelNoise, blocks16 }
    let retainedBytes: Int
    private let width: Int
    private let height: Int
    private let textures: [Data]

    static func selection(_ flag: String?) throws -> Pattern? {
        switch flag {
        case nil, "": return nil
        case "1": return .pixelNoise
        case "blocks16": return .blocks16
        default: throw Failure.flag
        }
    }

    static func retainedByteCount(profile: ArchiveProfile) throws -> Int {
        try profile.validate()
        let (luma, lumaOverflow) = profile.width.multipliedReportingOverflow(by: profile.height)
        let (frame, frameOverflow) = luma.addingReportingOverflow(luma / 2)
        let (total, totalOverflow) = frame.multipliedReportingOverflow(by: textureCount)
        guard !lumaOverflow, !frameOverflow, !totalOverflow,
              total > 0, total <= maximumRetainedBytes else { throw Failure.capacity }
        return total
    }

    init(profile: ArchiveProfile, seed: UInt64 = Self.seed, pattern: Pattern = .pixelNoise) throws {
        // Complete validation and checked multiplication before the first allocation.
        retainedBytes = try Self.retainedByteCount(profile: profile)
        let width = profile.width, height = profile.height
        self.width = width; self.height = height
        let lumaBytes = width * height
        let frameBytes = retainedBytes / Self.textureCount
        var generator = Generator(state: seed)
        var prepared: [Data] = []
        prepared.reserveCapacity(Self.textureCount)
        for _ in 0..<Self.textureCount {
            var texture = Data(count: frameBytes)
            texture.withUnsafeMutableBytes { storage in
                let bytes = storage.bindMemory(to: UInt8.self)
                memset(bytes.baseAddress!, 32, lumaBytes)
                memset(bytes.baseAddress!.advanced(by: lumaBytes), 128, frameBytes - lumaBytes)
                for plane in 0..<2 {
                    let rows = Self.rows(height: height, plane: plane)
                    let offset = plane == 0 ? 0 : lumaBytes
                    for row in rows {
                        var word: UInt64 = 0
                        for column in 0..<width {
                            if column.isMultiple(of: 8) { word = generator.next() }
                            let range: UInt64 = plane == 0 ? 220 : 225
                            bytes[offset + row * width + column] = UInt8(16 + (word & 255) % range)
                            word >>= 8
                        }
                    }
                }
                if case .blocks16 = pattern {
                    Self.formBlocks16(in: bytes, width: width, height: height)
                }
            }
            prepared.append(texture)
        }
        textures = prepared
    }

    /// Transform each disjoint cell after generating the original noise, preserving
    /// its RNG progression. Keep only center scalars; no second image allocation.
    private static func formBlocks16(in bytes: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int) {
        for plane in 0..<2 {
            let rows = Self.rows(height: height, plane: plane)
            let offset = plane == 0 ? 0 : width * height
            let components = plane == 0 ? 1 : 2
            let cellHeight = 16 / components
            for top in stride(from: rows.lowerBound, to: rows.upperBound, by: cellHeight) {
                let bottom = min(top + cellHeight, rows.upperBound)
                let centerRow = top + (bottom - top) / 2
                for left in stride(from: 0, to: width, by: 16) {
                    let right = min(left + 16, width)
                    let centerColumn = left + ((right - left) / components / 2) * components
                    let center = offset + centerRow * width + centerColumn
                    let first = bytes[center]
                    let second = plane == 1 ? bytes[center + 1] : 0
                    for row in top..<bottom {
                        for column in stride(from: left, to: right, by: components) {
                            bytes[offset + row * width + column] = first
                            if plane == 1 { bytes[offset + row * width + column + 1] = second }
                        }
                    }
                }
            }
        }
    }

    /// Caller owns and has locked a newly allocated destination pixel buffer.
    func copyMiddle(into pixel: CVPixelBuffer, frame: Int) throws {
        guard frame >= 0, CVPixelBufferGetPlaneCount(pixel) == 2,
              CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else { throw Failure.buffer }
        try textures[frame % Self.textureCount].withUnsafeBytes { texture in
            for plane in 0..<2 {
                let rows = Self.rows(height: height, plane: plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixel, plane),
                      stride >= width, CVPixelBufferGetHeightOfPlane(pixel, plane) >= rows.upperBound
                else { throw Failure.buffer }
                let offset = plane == 0 ? 0 : width * height
                for row in rows {
                    memcpy(destination.advanced(by: row * stride),
                           texture.baseAddress!.advanced(by: offset + row * width), width)
                }
            }
        }
    }

    private static func rows(height: Int, plane: Int) -> Range<Int> {
        let lower = height / 3, upper = height * 5 / 6
        // Chroma covers two luma rows. Preserve a boundary pair if either row
        // lies outside the allowed band, including scaled odd band boundaries.
        return plane == 0 ? lower..<upper : (lower + 1) / 2..<upper / 2
    }

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            // SplitMix64: fixed arithmetic, seed, and byte order across hosts.
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            return value ^ (value >> 31)
        }
    }
}
#endif
