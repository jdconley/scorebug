import Foundation
import Testing
@testable import SRTHaishinKit

@Suite struct SRTNonblockingSendTests {
    private enum Failure: Error { case write, restore }
    @Test(arguments: [false, true]) func restoresOriginalModeForSuccessAndBackpressure(accepted: Bool) throws {
        var mode = true, changes: [Bool] = []
        let result = try SRTNonblockingSend.perform(get: { mode }, set: { mode = $0; changes.append($0) }, send: {
            #expect(!mode); return accepted
        })
        #expect(result == accepted)
        #expect(mode && changes == [false, true])
    }
    @Test func alreadyNonblockingModeIsNotChanged() throws {
        #expect(try SRTNonblockingSend.perform(get: { false }, set: { _ in Issue.record("Unexpected flag write") }, send: { true }))
    }
    @Test func restoresModeWhenNativeSendFails() {
        var mode = true
        #expect(throws: Failure.write) {
            try SRTNonblockingSend.perform(get: { mode }, set: { mode = $0 }, send: { throw Failure.write })
        }
        #expect(mode)
    }
    @Test func restorationFailureIsNotHiddenByBackpressure() {
        #expect(throws: SRTNonblockingSend.RestorationFailure.self) {
            try SRTNonblockingSend.perform(get: { true }, set: { if $0 { throw Failure.restore } }, send: { false })
        }
    }
    @Test func failedModeChangeNeverSubmits() {
        #expect(throws: Failure.write) {
            try SRTNonblockingSend.perform(get: { true }, set: { _ in throw Failure.write }, send: {
                Issue.record("Sent with blocking mode"); return true
            })
        }
    }
}
