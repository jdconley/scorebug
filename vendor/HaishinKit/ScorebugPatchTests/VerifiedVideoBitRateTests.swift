import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import HaishinKit

struct VerifiedVideoBitRateTests {
    private final class PropertySession: VTSessionConvertible {
        var writes: [VTSessionOption] = []
        var reads: [String] = []
        var writeStatuses: [OSStatus] = []
        var readResults: [String: (status: OSStatus, value: CFTypeRef?)] = [:]
        var values: [String: CFTypeRef] = [:]

        func setOption(_ option: VTSessionOption) -> OSStatus {
            writes.append(option)
            let status = writeStatuses.isEmpty ? noErr : writeStatuses.removeFirst()
            if status == noErr { values[option.key.CFString as String] = option.value }
            return status
        }
        func copyOption(_ key: VTSessionOptionKey) -> (status: OSStatus, value: CFTypeRef?) {
            let name = key.CFString as String
            reads.append(name)
            return readResults[name] ?? (noErr, values[name])
        }
        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus { fatalError("Unexpected batch write") }
        func convert(_ sampleBuffer: CMSampleBuffer, continuation: PublishingQueue<CMSampleBuffer>?, encoderCompletionObserver: VideoEncoderCompletionObserver?) throws { fatalError("Unexpected encode") }
        func completeFrames() -> OSStatus { fatalError("Unexpected drain") }
        func invalidate() { fatalError("Unexpected invalidation") }
    }

    private let rateKey = kVTCompressionPropertyKey_AverageBitRate as String
    private let limitsKey = kVTCompressionPropertyKey_DataRateLimits as String

    @Test func defaultLimitsFollowNewRateAndOriginalSettingsRemainUnchanged() throws {
        let current = VideoCodecSettings(bitRate: 1_000_000)
        let session = PropertySession()
        let updated = try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        #expect(updated.bitRate == 2_000_000)
        #expect(current.bitRate == 1_000_000)
        #expect(updated.dataRateLimits == [0, 0])
        #expect(session.writes.map { $0.key.CFString as String } == [rateKey, limitsKey])
        #expect(session.values[limitsKey] as? [Double] == [375_000, 1])
        #expect(session.reads == [rateKey, limitsKey])
        #expect(updated.makeOptions().first { $0.key == .dataRateLimits }?.value as? [Double] == [375_000, 1])
    }

    @Test func explicitLimitsArePreserved() throws {
        let current = VideoCodecSettings(dataRateLimits: [250_000, 2])
        let session = PropertySession()
        let updated = try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        #expect(updated.dataRateLimits == [250_000, 2])
        #expect(session.values[limitsKey] as? [Double] == [250_000, 2])
    }

    @Test func nilLimitsOnlyVerifyAverageRate() throws {
        let current = VideoCodecSettings(dataRateLimits: nil)
        let session = PropertySession()
        let updated = try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        #expect(updated.dataRateLimits == nil)
        #expect(session.writes.count == 1)
        #expect(session.reads == [rateKey])
    }

    @Test func unchangedRateStillWritesAndVerifies() throws {
        let current = VideoCodecSettings()
        let session = PropertySession()
        _ = try VerifiedVideoBitRate.apply(current.bitRate, to: current, session: session)
        #expect(session.writes.count == 2)
        #expect(session.reads == [rateKey, limitsKey])
    }

    @Test(arguments: [0, -1, Int(Int32.max) + 1, Int.max])
    func invalidRateHasNoNativeSideEffects(rate: Int) {
        let session = PropertySession()
        #expect(throws: VideoBitRateUpdateError.invalidBitRate) {
            try VerifiedVideoBitRate.apply(rate, to: .default, session: session)
        }
        #expect(session.writes.isEmpty && session.reads.isEmpty)
    }

    @Test func maximumRepresentableRateSucceeds() throws {
        let updated = try VerifiedVideoBitRate.apply(Int(Int32.max), to: .default, session: PropertySession())
        #expect(updated.bitRate == Int(Int32.max))
    }

    @Test func unsupportedModeHasNoNativeSideEffects() {
        let session = PropertySession()
        let current = VideoCodecSettings(bitRateMode: .constant)
        #expect(throws: VideoBitRateUpdateError.unsupportedRateControl) {
            try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        }
        #expect(session.writes.isEmpty && session.reads.isEmpty)
    }

    @Test(arguments: [[], [1], [1, 2, 3], [-1, 1], [1, -1], [Double.nan, 1], [1, Double.infinity]])
    func invalidLimitsHaveNoNativeSideEffects(limits: [Double]) {
        let session = PropertySession()
        let current = VideoCodecSettings(dataRateLimits: limits)
        #expect(throws: VideoBitRateUpdateError.invalidDataRateLimits) {
            try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        }
        #expect(session.writes.isEmpty && session.reads.isEmpty)
    }

    @Test(arguments: [0, 1])
    func writeFailureDoesNotPublishSettings(failureIndex: Int) {
        let session = PropertySession()
        session.writeStatuses = failureIndex == 0 ? [-12900] : [noErr, -12900]
        let current = VideoCodecSettings(bitRate: 1_000_000)
        let key = failureIndex == 0 ? rateKey : limitsKey
        #expect(throws: VideoBitRateUpdateError.writeFailed(property: key, status: -12900)) {
            try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        }
        #expect(current.bitRate == 1_000_000)
        #expect(session.writes.count == failureIndex + 1)
        #expect(session.reads.isEmpty)
    }

    @Test(arguments: [false, true])
    func readFailureDoesNotPublishSettings(failLimits: Bool) {
        let session = PropertySession()
        let key = failLimits ? limitsKey : rateKey
        session.readResults[key] = (-12901, nil)
        let current = VideoCodecSettings(bitRate: 1_000_000)
        #expect(throws: VideoBitRateUpdateError.readFailed(property: key, status: -12901)) {
            try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        }
        #expect(current.bitRate == 1_000_000)
        #expect(session.writes.count == 2)
    }

    @Test func malformedAndMismatchedRateReadbacksAreRejected() {
        let badValues: [CFTypeRef?] = [nil, kCFBooleanTrue, "2000000" as NSString,
            NSNumber(value: 2_000_001), NSNumber(value: 2_000_000.5), NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity), NSNumber(value: UInt64.max), [2_000_000] as NSArray]
        for value in badValues {
            let session = PropertySession()
            session.readResults[rateKey] = (noErr, value)
            #expect(throws: VideoBitRateUpdateError.readbackMismatch(property: rateKey)) {
                try VerifiedVideoBitRate.apply(2_000_000, to: .default, session: session)
            }
        }
    }

    @Test func malformedAndMismatchedLimitReadbacksAreRejected() {
        let badValues: [CFTypeRef?] = [nil, NSNumber(value: 375_000), "375000,1" as NSString,
            [] as NSArray, [375_000] as NSArray, [375_000, 1, 1] as NSArray,
            [375_001, 1] as NSArray, [375_000, 2] as NSArray,
            [NSNumber(value: 375_000), kCFBooleanTrue!] as NSArray,
            [375_000, Double.nan] as NSArray, [Double.infinity, 1] as NSArray]
        for value in badValues {
            let session = PropertySession()
            session.readResults[limitsKey] = (noErr, value)
            #expect(throws: VideoBitRateUpdateError.readbackMismatch(property: limitsKey)) {
                try VerifiedVideoBitRate.apply(2_000_000, to: .default, session: session)
            }
        }
    }

    @Test func integerReadbackMustNotMatchByLossyDoubleConversion() {
        let current = VideoCodecSettings(dataRateLimits: [9_007_199_254_740_992, 1])
        let session = PropertySession()
        session.readResults[limitsKey] = (noErr, [NSNumber(value: Int64(9_007_199_254_740_993)), NSNumber(value: 1)] as NSArray)
        #expect(throws: VideoBitRateUpdateError.readbackMismatch(property: limitsKey)) {
            try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
        }
    }

    @Test func booleanReadbackMustNotMatchNumericOne() {
        let session = PropertySession()
        session.readResults[rateKey] = (noErr, kCFBooleanTrue)
        #expect(throws: VideoBitRateUpdateError.readbackMismatch(property: rateKey)) {
            try VerifiedVideoBitRate.apply(1, to: .default, session: session)
        }
    }

    @Test func fractionalExplicitLimitsAndPartialDefaultsRemainExact() throws {
        for limits in [[375_000.5, 0.5], [0, 2], [250_000, 0]] {
            let current = VideoCodecSettings(dataRateLimits: limits)
            let session = PropertySession()
            let updated = try VerifiedVideoBitRate.apply(2_000_000, to: current, session: session)
            #expect(updated.dataRateLimits == limits)
            #expect(session.values[limitsKey] as? [Double] == updated.effectiveDataRateLimits)
        }
    }

    @Test func legacyOptionsKeepPartialZeroDefaultsAndMalformedOmission() {
        let partial = VideoCodecSettings(bitRate: 2_000_000, dataRateLimits: [0, 2])
        #expect(partial.makeOptions().first { $0.key == .dataRateLimits }?.value as? [Double] == [375_000, 2])
        let malformed = VideoCodecSettings(dataRateLimits: [1])
        #expect(malformed.makeOptions().allSatisfy { $0.key != .dataRateLimits })
        let invalid = VideoCodecSettings(dataRateLimits: [-1, 1])
        #expect(invalid.makeOptions().first { $0.key == .dataRateLimits }?.value as? [Double] == [-1, 1])
    }
}
