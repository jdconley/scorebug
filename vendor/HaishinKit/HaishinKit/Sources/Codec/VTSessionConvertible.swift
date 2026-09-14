import AVFoundation
import Foundation
import VideoToolbox

enum VTSessionError: Swift.Error {
    var status: OSStatus {
        switch self {
        case .failedToCreate(let status), .failedToPrepare(let status), .failedToConvert(let status): return status
        }
    }
    case failedToCreate(status: OSStatus)
    case failedToPrepare(status: OSStatus)
    case failedToConvert(status: OSStatus)
}

protocol VTSessionConvertible {
    func setOption(_ option: VTSessionOption) -> OSStatus
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?) throws
    func invalidate()
}

extension VTSessionConvertible where Self: VTSession {
    func setOption(_ option: VTSessionOption) -> OSStatus {
        return VTSessionSetProperty(self, key: option.key.CFString, value: option.value)
    }

    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
        var properties: [AnyHashable: AnyObject] = [:]
        for option in options {
            properties[option.key.CFString] = option.value
        }
        return VTSessionSetProperties(self, propertyDictionary: properties as CFDictionary)
    }
}
