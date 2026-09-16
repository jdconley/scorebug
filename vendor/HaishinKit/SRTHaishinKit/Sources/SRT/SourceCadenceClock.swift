import CoreMedia

/// Scalar scheduling only: no media retention, timers, or fixed added latency.
struct SourceCadenceClock {
    enum Failure: Swift.Error { case invalidSource, invalidClock, excessiveLead }
    private var firstPTS: CMTime?
    private var firstUptime: Double = 0
    private var lastPTS: CMTime?
    private var lastUptime: Double = 0

    mutating func delay(sourcePTS: CMTime, now: Double) throws -> Double {
        guard sourcePTS.isNumeric, sourcePTS.timescale > 0 else { throw Failure.invalidSource }
        guard now.isFinite, (0...1e12).contains(now) else { throw Failure.invalidClock }
        guard let firstPTS else {
            self.firstPTS = sourcePTS; firstUptime = now; lastPTS = sourcePTS; lastUptime = now
            return 0
        }
        guard sourcePTS.epoch == firstPTS.epoch, let lastPTS, sourcePTS > lastPTS else { throw Failure.invalidSource }
        guard now >= lastUptime else { throw Failure.invalidClock }
        // Subtract in CoreMedia before converting; large absolute PTS must not
        // erase individual frame deltas through floating-point cancellation.
        let delta = CMTimeSubtract(sourcePTS, firstPTS)
        guard delta.isNumeric, delta.seconds.isFinite, delta.seconds >= 0 else { throw Failure.invalidSource }
        let due = firstUptime + delta.seconds
        guard due.isFinite else { throw Failure.invalidClock }
        let delay = max(0, due - now)
        guard delay <= 1 else { throw Failure.excessiveLead }
        self.lastPTS = sourcePTS; lastUptime = now
        return delay
    }
}
