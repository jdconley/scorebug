import Foundation
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTStatisticsSamplingTests {
    @Test func clockIsSampledBeforeNativeCallAndClosedSocketCannotCollect() async {
        let socket = SRTSocket()
        let order = StatisticsSamplingOrder()
        _ = await socket.collectPerformanceData(using: { _ in order.record("native"); return 0 },
                                                 now: { order.record("clock"); return 12 })
        #expect(order.events == ["clock", "native"])
        await socket.stopRunning()
        let result = await socket.collectPerformanceData(using: { _ in order.record("late"); return 0 }, now: { 13 })
        #expect(result == SRT_ERROR)
        #expect(order.events == ["clock", "native"])
        #expect(await socket.performanceData.sampledAt == nil)
    }

    @Test func cachedReadsKeepActualCollectionTimeAndStopClearsAvailability() async {
        let socket = SRTSocket()
        #expect(await socket.performanceData.sampledAt == nil)
        let result = await socket.collectPerformanceData(using: { value in
            value.msTimeStamp = 1000; value.byteSentTotal = 5000; return 0
        }, now: { 12 })
        #expect(result == 0)
        #expect(await socket.performanceData.sampledAt == 12)
        #expect(await socket.performanceData.byteSentTotal == 5000)
        #expect(await socket.performanceData.sampledAt == 12)
        _ = await socket.collectPerformanceData(using: { value in
            value.msTimeStamp = 2000; value.byteSentTotal = 8000; return 0
        }, now: { 13 })
        #expect(await socket.performanceData.sampledAt == 13)
        await socket.stopRunning()
        #expect(await socket.performanceData.sampledAt == nil)
    }
    @Test func failedCollectionCannotTimestampCorruptOrOldStatisticsAsFresh() async {
        let socket = SRTSocket()
        _ = await socket.collectPerformanceData(using: { value in value.byteSentTotal = 5000; return 0 }, now: { 12 })
        let result = await socket.collectPerformanceData(using: { value in value.byteSentTotal = 1; return SRT_ERROR }, now: { 13 })
        #expect(result == SRT_ERROR)
        #expect(await socket.performanceData.sampledAt == nil)
        #expect(await socket.performanceData.byteSentTotal == 5000)
        await socket.stopRunning()
    }
}

private final class StatisticsSamplingOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}
