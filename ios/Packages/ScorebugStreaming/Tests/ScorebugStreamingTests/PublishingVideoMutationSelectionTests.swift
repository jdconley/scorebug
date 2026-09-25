import CoreMedia
import Foundation
import ScorebugMedia
import XCTest
@testable import HaishinKit
@testable import SRTHaishinKit
@testable import ScorebugStreaming

final class PublishingVideoMutationSelectionTests: XCTestCase {
    private let configuration = UUID(), encoder = UUID(), previous = UUID()
    func testVerifiedNativeSelectionRequiresEveryExactScalar() {
        let selected = PublishingBitRateChange(publishingGeneration: 7,
            configuration: .init(id: configuration, encoderSessionID: encoder, bitRate: 600_000)!,
            acceptedAt: 0, lastSubmittedSourcePTS: CMTime(value: 30, timescale: 30))!
        for field in ["", "generation", "configuration", "encoder", "rate", "accepted", "signedZero", "nilPTS", "value", "timescale", "flags", "epoch"] {
            let native = SRTStream.VideoBitRateReceipt(publishingGeneration: field == "generation" ? 8 : 7,
                change: .init(settings: .init(bitRate: 600_000),
                    configuration: .init(id: field == "configuration" ? UUID() : configuration,
                        encoderSessionID: field == "encoder" ? UUID() : encoder, bitRate: field == "rate" ? 600_001 : 600_000),
                    acceptedAt: field == "accepted" ? 1 : (field == "signedZero" ? -0.0 : 0),
                    lastSubmittedSourcePTS: field == "nilPTS" ? nil : CMTime(value: field == "value" || field == "timescale" ? 60 : 30,
                        timescale: field == "timescale" ? 60 : 30, flags: field == "flags" ? [.valid, .hasBeenRounded] : .valid,
                        epoch: field == "epoch" ? 1 : 0)))
            XCTAssertEqual(selected.matchesNative(native), field.isEmpty, field)
        }
        let native = selected.nativeExpectation
        XCTAssertEqual(native.configurationID, configuration); XCTAssertEqual(native.encoderSessionID, encoder)
        XCTAssertEqual(native.bitRate, 600_000); XCTAssertEqual(native.acceptedAt.bitPattern, selected.acceptedAt.bitPattern)
        XCTAssertEqual(native.lastSubmittedSourcePTS?.value, 30); XCTAssertEqual(native.lastSubmittedSourcePTS?.timescale, 30)
    }

    func testReplacementMappingRequiresExactIssuedMediaReceipt() {
        let original = replacement()
        let native = SRTStream.VideoReplacementReceipt(publishingGeneration: 7, encoderSessionID: encoder,
            previousEncoderSessionID: previous, lastOldSourcePTS: original.lastOldSourcePTS,
            firstNewSourcePTS: original.firstNewSourcePTS, width: 426, height: 240, rawVideoFramesDropped: 1)
        let mapping = PublishingVideoReplacementMapping(native: native, media: original)
        for field in ["", "profile", "generation", "previous", "encoder", "oldValue", "oldTimescale", "oldFlags", "newValue", "newTimescale", "newFlags", "dropped", "acknowledged", "signedZero"] {
            XCTAssertEqual(mapping.matches(replacement(changing: field)), field.isEmpty, field)
        }
    }

    private func replacement(changing field: String = "") -> PublishingVideoProfileChange {
        let profile = field == "profile" ? PublishingVideoProfile.low360 : .low240
        return .init(profile: profile, publishingGeneration: field == "generation" ? 8 : 7,
            previousEncoderSessionID: field == "previous" ? UUID() : previous, encoderSessionID: field == "encoder" ? UUID() : encoder,
            lastOldSourcePTS: CMTime(value: field == "oldValue" ? 29 : (field == "oldTimescale" ? 60 : 30),
                timescale: field == "oldTimescale" ? 60 : 30, flags: field == "oldFlags" ? [.valid, .hasBeenRounded] : .valid, epoch: 0),
            firstNewSourcePTS: CMTime(value: field == "newValue" ? 32 : (field == "newTimescale" ? 62 : 31),
                timescale: field == "newTimescale" ? 60 : 30, flags: field == "newFlags" ? [.valid, .hasBeenRounded] : .valid, epoch: 0),
            width: profile.width, height: profile.height, rawVideoFramesDropped: field == "dropped" ? 2 : 1,
            acknowledgedAt: field == "acknowledged" ? 1 : (field == "signedZero" ? -0.0 : 0))!
    }
}
