import Foundation
import HaishinKit
import libsrt
import Testing
@testable import SRTHaishinKit

@Suite struct SRTSocketPaddingTests {
    @Test(arguments: [false, true]) func nativeFlagRestoredAndAcceptedPaddingCounted(original: Bool) async throws {
        let sent = PaddingBytes()
        let socket = SRTSocket(sender: { sent.append($0); return Int32($0.count) }, statisticsReader: healthy)
        await socket.startRunning()
        try await socket.setSocketOption(.init(name: sndsyn, value: original ? 1 : 0))
        let now = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: sample(now - 0.02), at: now - 0.02)
        try await socket.sendPadding(probe, pendingMedia: TransportOutputAccounting())
        #expect(sent.data == SRTProbeMessage.encode(id: probe.id, generation: 1, sequence: 0, bitRate: 2_000_000))
        #expect(sent.data.count == 1316)
        #expect(sent.data[4..<12] == Data("SBUGPRB1".utf8))
        #expect(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }).acceptedPayloadBytes == 1316)
        #expect(try await socket.getSocketOption(sndsyn).intValue == (original ? 1 : 0))
        await socket.stopRunning()
    }
    @Test func revocationAndMissingStatisticsCannotWriteOrFailOrdinaryMedia() async throws {
        let sent = PaddingBytes()
        let socket = SRTSocket(sender: { sent.append($0); return Int32($0.count) }, statisticsReader: { _, _, _, _ in SRT_ERROR })
        await socket.startRunning()
        let now = ProcessInfo.processInfo.systemUptime
        let probe = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: sample(now - 0.02), at: now - 0.02)
        try await socket.sendPadding(probe, pendingMedia: TransportOutputAccounting())
        #expect(sent.data.isEmpty)
        #expect(probe.snapshot(now: { ProcessInfo.processInfo.systemUptime }).reason == .unavailableStatistics)
        #expect(await socket.publishingError == nil)
        let cancelled = try SRTBandwidthProbe(bitRate: 2_000_000, generation: 1, statistics: sample(now), at: now)
        cancelled.cancel(.closed)
        try await socket.sendPadding(cancelled, pendingMedia: TransportOutputAccounting())
        try await socket.send(Data([1,2,3]))
        #expect(sent.data == Data([1,2,3]))
        await socket.stopRunning()
    }
    private var sndsyn: SRTSocketOption.Name { .init(rawValue: "sndsyn", symbol: SRTO_SNDSYN, restriction: .post, type: .bool) }
    private func sample(_ at: Double) -> SRTPerformanceData {
        var mon = CBytePerfMon(); mon.msRTT = 2
        return .init(mon: mon, sampledAt: at)
    }
}
private func healthy(_ socket: SRTSOCKET, _ mon: inout CBytePerfMon, _ clear: Int32, _ instantaneous: Int32) -> Int32 {
    mon.msRTT = 2; return 0
}
private final class PaddingBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
}
