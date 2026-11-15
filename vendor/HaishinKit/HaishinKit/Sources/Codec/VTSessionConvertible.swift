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

/// Synchronous notification of a qualifying native video encoder output.
/// Runs on the VideoToolbox callback thread before downstream queue admission.
/// Keep work bounded: do not perform I/O, wait, or create a task per frame.
public typealias VideoEncoderCompletionObserver = @Sendable (_ sourcePTS: CMTime, _ outputPTS: CMTime) -> Void

protocol VTSessionConvertible {
    func setOption(_ option: VTSessionOption) -> OSStatus
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?)
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws
    func completeFrames() -> OSStatus
    func invalidate()
}

extension VTSessionConvertible where Self: VTSession {
    func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(self, key: key.CFString, allocator: kCFAllocatorDefault, valueOut: &value)
        return (status, value)
    }

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
