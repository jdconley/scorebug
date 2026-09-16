import Foundation
import VideoToolbox

/// Read-only and bounded. Preserve failed property-copy status rather than
/// replacing an unavailable native value with a default.
enum NativeEncoderSnapshot {
    static let keys = [
        "EncoderID", "UsingHardwareAcceleratedVideoEncoder", "AverageBitRate", "DataRateLimits",
        "RealTime", "ExpectedFrameRate", "ProfileLevel", "AllowFrameReordering", "Quality",
        "MaxAllowedFrameQP", "MinAllowedFrameQP", "ConstantBitRate", "MaxFrameDelayCount",
        "MaxKeyFrameIntervalDuration"
    ]
    enum Failure: Error { case unsupportedValue, oversizedValue }

    static func capture(_ session: VTCompressionSession) throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        var supported: CFDictionary?
        let queryStatus = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported)
        let dictionary = queryStatus == noErr ? supported as NSDictionary? : nil
        var properties: [String: Any] = [:]
        for key in keys {
            let entry = dictionary?[key] as? NSDictionary
            var value: CFTypeRef?
            let status = VTSessionCopyProperty(session, key: key as CFString,
                                              allocator: kCFAllocatorDefault, valueOut: &value)
            properties[key] = [
                "supported": entry != nil, "status": status,
                "value": status == noErr ? try scalar(value) : NSNull(),
                "type": try text(entry?[kVTPropertyTypeKey]),
                "readWriteStatus": try text(entry?[kVTPropertyReadWriteStatusKey])
            ] as [String: Any]
        }
        return ["supportedQueryStatus": queryStatus, "properties": properties,
                "collectedAt": began, "completedAt": ProcessInfo.processInfo.systemUptime]
    }

    private static func text(_ value: Any?) throws -> Any {
        guard let value else { return NSNull() }
        guard let string = value as? String else { throw Failure.unsupportedValue }
        guard string.count <= 256 else { throw Failure.oversizedValue }
        return string
    }
    private static func scalar(_ value: CFTypeRef?) throws -> Any {
        guard let value else { return NSNull() }
        switch CFGetTypeID(value) {
        case CFBooleanGetTypeID(): return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        case CFNumberGetTypeID():
            let number = unsafeDowncast(value, to: NSNumber.self)
            guard number.doubleValue.isFinite else { throw Failure.unsupportedValue }
            return number
        case CFStringGetTypeID(): return try text(value)
        case CFArrayGetTypeID():
            let array = unsafeDowncast(value, to: NSArray.self)
            guard array.count <= 8 else { throw Failure.oversizedValue }
            return try (0..<array.count).map { index -> NSNumber in
                let item = array[index] as AnyObject
                guard CFGetTypeID(item) == CFNumberGetTypeID(), let number = item as? NSNumber,
                      number.doubleValue.isFinite else { throw Failure.unsupportedValue }
                return number
            }
        default: throw Failure.unsupportedValue
        }
    }
}
