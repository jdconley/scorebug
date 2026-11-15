import Foundation

struct ControlPollSchedule {
    private var slot: ContinuousClock.Instant
    private var previousInterval: Duration?
    init(start: ContinuousClock.Instant) { slot = start }
    mutating func nextDeadline(startedAt: ContinuousClock.Instant, completedAt: ContinuousClock.Instant,
                               interval: Duration) -> ContinuousClock.Instant {
        precondition(interval > .zero)
        if previousInterval != interval { slot = startedAt }
        previousInterval = interval
        let elapsed = slot.duration(to: completedAt)
        // Advance directly to the first future slot, never replay missed polls.
        let skipped = max(0, (elapsed / interval).rounded(.down))
        slot += interval * (skipped + 1)
        return slot
    }
    @MainActor static func run(now: () -> ContinuousClock.Instant = { .now },
        sleepUntil: (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0, clock: .continuous) },
        interval: () -> Duration, poll: () async -> Void) async {
        var schedule = Self(start: now())
        while !Task.isCancelled {
            let startedAt = now()
            await poll()
            guard !Task.isCancelled else { return }
            let deadline = schedule.nextDeadline(startedAt: startedAt, completedAt: now(), interval: interval())
            do { try await sleepUntil(deadline) } catch { return }
        }
    }
}
