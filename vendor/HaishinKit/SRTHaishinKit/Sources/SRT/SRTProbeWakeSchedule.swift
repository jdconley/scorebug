import Foundation

/// One optional probe's wake-only clock. The publication owns and joins run().
/// A strict timer avoids the measured several-ms Task.sleep coalescing, but is
/// still best-effort: token/lease checks at submission remain authoritative.
final class SRTProbeWakeSchedule: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    private init(probe: SRTBandwidthProbe, wake: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.scorebug.srt.probe-wake", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let delay = probe.nextOpportunityDelay(now: { ProcessInfo.processInfo.systemUptime }) else {
                timer.cancel(); return
            }
            if delay == 0 { wake() }
            // At most 500 callbacks/s while media delays a ready probe. Each
            // callback coalesces a signal; it never banks bytes or sends media.
            timer.schedule(deadline: .now() + min(0.05, max(0.002, delay)), leeway: .nanoseconds(0))
        }
        timer.schedule(deadline: .now() + .milliseconds(2), leeway: .nanoseconds(0))
    }

    static func run(probe: SRTBandwidthProbe, wake: @escaping @Sendable () -> Void) async {
        let schedule = SRTProbeWakeSchedule(probe: probe, wake: wake)
        await withTaskCancellationHandler {
            // AsyncStream iteration would end immediately on task cancellation,
            // before an entered handler returned. This continuation instead joins
            // the dispatch cancellation handler, including early cancellation
            // before resume. The timer never awaits a socket or stream actor.
            await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                schedule.timer.setCancelHandler { completion.resume() }
                schedule.timer.resume()
            }
        } onCancel: {
            schedule.timer.cancel()
        }
    }
}
