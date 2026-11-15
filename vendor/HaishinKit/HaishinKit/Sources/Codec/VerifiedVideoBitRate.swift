import Foundation
import VideoToolbox

/// A verified live bitrate update could not be applied to the active encoder.
public enum VideoBitRateUpdateError: Error, Equatable, Sendable {
    case invalidBitRate
    case unsupportedRateControl
    case invalidDataRateLimits
    case notEncoding
    case sessionInvalidated
    case writeFailed(property: String, status: Int32)
    case readFailed(property: String, status: Int32)
    case readbackMismatch(property: String)
}

/// Updates only native rate properties. The owner publishes returned settings after success.
enum VerifiedVideoBitRate {
    static func apply(_ bitRate: Int, to current: VideoCodecSettings,
                      session: any VTSessionConvertible) throws -> VideoCodecSettings {
        guard bitRate > 0, bitRate <= Int32.max else {
            throw VideoBitRateUpdateError.invalidBitRate
        }
        guard current.bitRateMode == .average else {
            throw VideoBitRateUpdateError.unsupportedRateControl
        }
        var updated = current
        updated.bitRate = bitRate
        let limits = updated.effectiveDataRateLimits
        if updated.dataRateLimits != nil {
            guard let limits, limits.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw VideoBitRateUpdateError.invalidDataRateLimits
            }
        }

        try write(.init(key: .averageBitRate, value: NSNumber(value: bitRate)), session: session)
        if let limits {
            try write(.init(key: .dataRateLimits, value: limits as NSArray), session: session)
        }
        let nativeRate = try read(.averageBitRate, session: session)
        guard matchesNumber(nativeRate, expected: Double(bitRate)) else {
            throw VideoBitRateUpdateError.readbackMismatch(property: name(.averageBitRate))
        }
        if let limits {
            let nativeLimits = try read(.dataRateLimits, session: session)
            guard let nativeLimits, CFGetTypeID(nativeLimits) == CFArrayGetTypeID() else {
                throw VideoBitRateUpdateError.readbackMismatch(property: name(.dataRateLimits))
            }
            // Inspect the length before touching elements so work stays bounded to two values.
            let array = unsafeDowncast(nativeLimits, to: NSArray.self)
            guard array.count == 2,
                  matchesNumber(array[0] as AnyObject, expected: limits[0]),
                  matchesNumber(array[1] as AnyObject, expected: limits[1]) else {
                throw VideoBitRateUpdateError.readbackMismatch(property: name(.dataRateLimits))
            }
        }
        return updated
    }

    private static func name(_ key: VTSessionOptionKey) -> String {
        key.CFString as String
    }

    private static func write(_ option: VTSessionOption, session: any VTSessionConvertible) throws {
        let status = session.setOption(option)
        guard status == noErr else {
            throw VideoBitRateUpdateError.writeFailed(property: name(option.key), status: status)
        }
    }

    private static func read(_ key: VTSessionOptionKey, session: any VTSessionConvertible) throws -> CFTypeRef? {
        let result = session.copyOption(key)
        guard result.status == noErr else {
            throw VideoBitRateUpdateError.readFailed(property: name(key), status: result.status)
        }
        return result.value
    }

    private static func matchesNumber(_ value: CFTypeRef?, expected: Double) -> Bool {
        // CFBoolean bridges to NSNumber, so check the native type before any conversion.
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return false }
        let number = unsafeDowncast(value, to: CFNumber.self)
        if !CFNumberIsFloatType(number) {
            var integer: Int64 = 0
            guard CFNumberGetValue(number, .sInt64Type, &integer),
                  let actual = Double(exactly: integer) else { return false }
            return actual == expected
        }
        var actual = 0.0
        guard CFNumberGetValue(number, .doubleType, &actual), actual.isFinite else { return false }
        return actual == expected
    }
}
