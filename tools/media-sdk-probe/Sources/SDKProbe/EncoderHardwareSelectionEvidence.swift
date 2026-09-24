import Foundation
import ScorebugStreaming

/// JSON projection of cached session-selection evidence, produced after stop.
/// No diagnostic outcome supplies streaming health or upgrade authority.
public func encoderHardwareSelectionEvidence(_ selection: SRTPublisher.EncoderHardwareSelection?) -> [String: Any]? {
    guard let selection else { return nil }
    let state: String, status: Int32?
    switch selection {
    case .hardware: state = "hardware"; status = nil
    case .software: state = "software"; status = nil
    case .readFailed(let value): state = "readFailed"; status = value
    case .missingValue: state = "missingValue"; status = nil
    case .invalidType: state = "invalidType"; status = nil
    case .notQueriedOnPlatform: state = "notQueriedOnPlatform"; status = nil
    }
    return ["state": state, "nativeStatus": status as Any? ?? NSNull()]
}
