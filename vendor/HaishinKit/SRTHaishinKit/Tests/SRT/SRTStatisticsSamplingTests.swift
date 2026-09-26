import Foundation
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTStatisticsSamplingTests {
    @Test func demandSamplesCollectWithoutClearingMonitorCountersAndCachedReadsStayCached() async throws {
        let reader = StatisticsReader()
        let socket = SRTSocket(sender: { Int32($0.count) }, statisticsReader: { reader.read($0, &$1, $2, $3) })
        await socket.startRunning()
        let before = ProcessInfo.processInfo.systemUptime
        let first = try #require(await socket.samplePerformanceData())
        let firstTime = try #require(first.sampledAt)
        #expect(firstTime >= before)
        #expect(first.byteSentTotal == 100)
        #expect(await socket.performanceData.sampledAt == firstTime)
        #expect(reader.flags == [0])
        let second = try #require(await socket.samplePerformanceData())
        #expect(second.sampledAt! >= firstTime)
        #expect(second.byteSentTotal == 200)
        #expect(reader.flags == [0, 0])
        _ = await socket.makeNetworkTransportReport()
        #expect(reader.flags == [0, 0, 1])
        #expect(reader.instantaneousFlags == [1, 1, 1])
        await socket.stopRunning()
        #expect(await socket.samplePerformanceData() == nil)
        #expect(reader.flags == [0, 0, 1])
    }

    @Test(arguments: [false, true])
    func currentQueuePressureIsNotHiddenByMovingAverage(periodic: Bool) async throws {
        let socket = SRTSocket(sender: { Int32($0.count) }, statisticsReader: { _, value, _, instantaneous in
            value.msTimeStamp += 1
            value.msRTT = 50
            value.msSndTsbPdDelay = 1000
            // Native SRT can report a low moving average while the queue already
            // exceeds the recovery guard's half-delay ceiling.
            value.msSndBuf = instantaneous == 1 ? 600 : 100
            return 0
        })
        await socket.startRunning()
        var initial = CBytePerfMon()
        initial.msSndTsbPdDelay = 1000
        let before = ProcessInfo.processInfo.systemUptime
        var guardState = try #require(SRTProbeTransportGuard(statistics: .init(mon: initial, sampledAt: before), at: before))
        let sample: SRTPerformanceData
        if periodic {
            _ = await socket.makeNetworkTransportReport()
            sample = await socket.performanceData
        } else {
            sample = try #require(await socket.samplePerformanceData())
        }
        #expect(sample.msSndBuf == 600)
        let sampledAt = try #require(sample.sampledAt)
        #expect(guardState.observe(sample, at: sampledAt) == .transportPressure)
        await socket.stopRunning()
    }

    @Test func failedDemandSampleCannotExposePreviouslyFreshOrPartialNativeData() async throws {
        let reader = StatisticsReader()
        let socket = SRTSocket(sender: { Int32($0.count) }, statisticsReader: { reader.read($0, &$1, $2, $3) })
        await socket.startRunning()
        let first = try #require(await socket.samplePerformanceData())
        #expect(first.sampledAt != nil)
        reader.fail()
        #expect(await socket.samplePerformanceData() == nil)
        #expect(await socket.performanceData.sampledAt == nil)
        #expect(await socket.performanceData.byteSentTotal == 100)
        await socket.stopRunning()
    }

    @Test func connectionDemandReadUsesNativeCollectionAndRejectsClosedOrCancelledWork() async throws {
        let reader = StatisticsReader()
        let socket = SRTSocket(sender: { Int32($0.count) }, statisticsReader: { reader.read($0, &$1, $2, $3) })
        let connection = SRTConnection(socket: socket)
        #expect(await connection.samplePerformanceData() == nil)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        let first = try #require(await connection.samplePerformanceData())
        #expect(first.sampledAt != nil)
        #expect(reader.flags.contains(0))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await connection.samplePerformanceData()
        }
        #expect(await cancelled.value == nil)
        await connection.close()
        #expect(await connection.samplePerformanceData() == nil)
    }

    @Test(arguments: [false, true])
    func closeOrCancellationDiscardsNativeReadAlreadyInFlight(cancel: Bool) async throws {
        let gate = StatisticsReadGate()
        defer { gate.release() }
        let reader = StatisticsReader(gate: gate)
        let socket = SRTSocket(sender: { Int32($0.count) }, statisticsReader: { reader.read($0, &$1, $2, $3) })
        let connection = SRTConnection(socket: socket)
        try await connection.connect(URL(string: "srt://127.0.0.1:1"))
        let pending = Task.detached { await connection.samplePerformanceData() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.entered)
        if cancel {
            pending.cancel()
            gate.release()
            #expect(await pending.value == nil)
            await connection.close()
        } else {
            let closing = Task { await connection.close() }
            while await connection.connected && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(await connection.connected == false)
            gate.release()
            #expect(await pending.value == nil)
            await closing.value
            #expect(await connection.samplePerformanceData() == nil)
        }
        #expect(!gate.timedOut)
    }

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

private final class StatisticsReader: @unchecked Sendable {
    private let lock = NSLock()
    private var clears: [Int32] = []
    private var modes: [Int32] = []
    private var failure = false
    private let gate: StatisticsReadGate?
    init(gate: StatisticsReadGate? = nil) { self.gate = gate }
    var flags: [Int32] { lock.withLock { clears } }
    var instantaneousFlags: [Int32] { lock.withLock { modes } }
    func fail() { lock.withLock { failure = true } }
    func read(_ socket: SRTSOCKET, _ value: inout CBytePerfMon, _ clear: Int32, _ instantaneous: Int32) -> Int32 {
        if clear == 0 { gate?.block() }
        return lock.withLock {
            clears.append(clear)
            modes.append(instantaneous)
            value.byteSentTotal = failure ? 1 : UInt64(clears.count * 100)
            value.msTimeStamp = Int64(clears.count * 250)
            return failure ? SRT_ERROR : 0
        }
    }
}

private final class StatisticsReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false
    private var expired = false
    var entered: Bool { condition.withLock { didEnter } }
    var timedOut: Bool { condition.withLock { expired } }
    func block() {
        condition.lock()
        defer { condition.unlock() }
        didEnter = true
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { expired = true; break }
        }
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}
