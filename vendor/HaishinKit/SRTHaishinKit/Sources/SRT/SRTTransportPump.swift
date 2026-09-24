import Foundation
import HaishinKit

/// One publication's sole FIFO consumer. Never hops to the stream actor, which
/// may be occupied by a synchronous encoder submission. The owner cancels on
/// close and joins retirement before another publication may reuse a connection.
enum SRTTransportPump {
    static func run(output: AsyncStream<Data>, accounting: TransportOutputAccounting,
                    failure: PublishingFailureLatch, connection: SRTConnection,
                    connectionSession: UInt64, publishingGeneration: UInt64,
                    observer: (@Sendable (SRTStream.TransportSendObservation) -> Void)?) async {
        var iterator = output.makeAsyncIterator()
        var sequence: UInt64 = 0
        for await _ in accounting.wakes {
            guard !Task.isCancelled, failure.error == nil else { return }
            while accounting.pending > 0 {
                guard !Task.isCancelled, failure.error == nil else { return }
                guard let data = await iterator.next() else { return }
                guard !Task.isCancelled, failure.error == nil else { return }
                guard accounting.dequeue() else {
                    failure.fail(.muxerFailed(reason: String(describing: SRTStream.MuxerError.invalidPayload)))
                    return
                }
                if let observer {
                    sequence &+= 1
                    let attempt = sequence
                    let byteCount = data.count
                    observer(.init(publishingGeneration: publishingGeneration, sequence: attempt,
                        phase: .started, byteCount: byteCount, pendingPacketCount: accounting.pending,
                        observedAt: ProcessInfo.processInfo.systemUptime))
                    await connection.send(data, generation: connectionSession, socketSendObserver: { phase in
                        observer(.init(publishingGeneration: publishingGeneration, sequence: attempt,
                            phase: phase == .started ? .socketStarted : .socketReturned,
                            byteCount: byteCount, pendingPacketCount: accounting.pending,
                            observedAt: ProcessInfo.processInfo.systemUptime))
                    })
                    // Return is a diagnostic even if this attempt failed or closed.
                    observer(.init(publishingGeneration: publishingGeneration, sequence: attempt,
                        phase: .returned, byteCount: byteCount, pendingPacketCount: accounting.pending,
                        observedAt: ProcessInfo.processInfo.systemUptime))
                } else {
                    await connection.send(data, generation: connectionSession)
                }
                guard !Task.isCancelled, failure.error == nil else { return }
            }
            if let probe = accounting.probe {
                guard !Task.isCancelled, failure.error == nil else { return }
                await connection.sendPadding(probe, pendingMedia: accounting, generation: connectionSession)
            }
        }
    }
}
