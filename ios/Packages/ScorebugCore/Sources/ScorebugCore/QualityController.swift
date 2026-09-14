import Foundation

/// Pure live-video policy. Callers supply monotonic seconds and independently
/// measured telemetry; this type never configures capture, encoding, or archives.
/// Thresholds are initial qualification values, not a reliability guarantee.
public struct QualityController: Sendable {
    public struct Profile: Equatable, Sendable {
        public let id: String
        public let width: Int
        public let height: Int
        public let targetFPS: Int
        public let minimumBitrate: Int
        public let maximumBitrate: Int
        public init(id: String, width: Int, height: Int, targetFPS: Int = 30, minimumBitrate: Int, maximumBitrate: Int) {
            self.id = id; self.width = width; self.height = height; self.targetFPS = targetFPS
            self.minimumBitrate = minimumBitrate; self.maximumBitrate = maximumBitrate
        }
    }
    public struct Settings: Equatable, Sendable {
        public let profileID: String
        public let videoBitrate: Int
        public init(profileID: String, videoBitrate: Int) { self.profileID = profileID; self.videoBitrate = videoBitrate }
    }
    public enum Connectivity: Sendable { case connected, disconnected, unknown }
    public enum Pressure: Sendable { case nominal, elevated, unknown }
    public struct Receiver: Sendable {
        /// Unique source frames received in this window, never muxed/duplicated frames.
        public let freshFrames: Int
        /// Caller-normalized monotonic observation time for the completed window.
        public let observedAt: Double
        public init(freshFrames: Int, observedAt: Double) { self.freshFrames = freshFrames; self.observedAt = observedAt }
    }
    public struct SourceLoss: Sendable {
        public let expectedFrames: Int
        public let lostFrames: Int
        public init(expectedFrames: Int, lostFrames: Int) { self.expectedFrames = expectedFrames; self.lostFrames = lostFrames }
    }
    public struct Window: Sendable {
        public let attemptID: UUID
        public let sequence: UInt64
        public let appliedRevision: UInt64
        public let start: Double
        public let end: Double
        public let capturedFreshFrames: Int?
        public let encodedFreshFrames: Int?
        public let receiver: Receiver?
        public let sourceLoss: SourceLoss?
        /// Time-weighted mean fraction of the bounded live ingress queue occupied.
        public let meanQueueOccupancy: Double?
        /// Usable VIDEO bits/second after reserving audio and transport overhead.
        /// A configured bitrate or historical send throughput is not capacity evidence.
        public let usableVideoCapacity: Double?
        public let connectivity: Connectivity
        public let thermalPressure: Pressure
        public let workerPressure: Pressure
        public init(attemptID: UUID, sequence: UInt64, appliedRevision: UInt64, start: Double, end: Double,
                    capturedFreshFrames: Int?, encodedFreshFrames: Int?, receiver: Receiver?, sourceLoss: SourceLoss?,
                    meanQueueOccupancy: Double?, usableVideoCapacity: Double?, connectivity: Connectivity,
                    thermalPressure: Pressure, workerPressure: Pressure) {
            self.attemptID = attemptID; self.sequence = sequence; self.appliedRevision = appliedRevision
            self.start = start; self.end = end; self.capturedFreshFrames = capturedFreshFrames
            self.encodedFreshFrames = encodedFreshFrames; self.receiver = receiver; self.sourceLoss = sourceLoss
            self.meanQueueOccupancy = meanQueueOccupancy; self.usableVideoCapacity = usableVideoCapacity
            self.connectivity = connectivity; self.thermalPressure = thermalPressure; self.workerPressure = workerPressure
        }
    }
    public enum State: Equatable, Sendable { case unknown, healthy, degraded, disconnected, stalled, insufficient }
    public enum Reason: Equatable, Sendable {
        case missingCapture, missingEncoded, missingReceiver, staleReceiver, missingSourceLoss, missingQueue, missingCapacity
        case unknownConnectivity, unknownPressure, freshFrameFloor, sourceLoss, queuePressure, capacityHeadroom
        case thermalPressure, workerPressure, disconnected, stalled, minimumProfileInsufficient, recoveryQualified, telemetryGap
    }
    public struct Recommendation: Equatable, Sendable {
        public let attemptID: UUID
        public let windowSequence: UInt64
        public let appliedRevision: UInt64
        /// Advice expires with its telemetry, even if no newer window arrives.
        public let validUntil: Double
        public let settings: Settings
    }
    public struct Decision: Equatable, Sendable {
        public let state: State
        public let reasons: [Reason]
        public let recommendation: Recommendation?
    }
    public enum ValidationError: Error, Equatable {
        case invalidProfiles, invalidSettings, invalidTime, wrongAttempt, wrongAppliedRevision
        case invalidWindow, staleWindow, outOfOrder, staleRecommendation
    }

    public let profiles: [Profile]
    public let attemptID: UUID
    public private(set) var applied: Settings
    public private(set) var appliedRevision: UInt64 = 0
    private var lastNow: Double
    private var appliedAt: Double
    private var lastEnd: Double?
    private var lastSequence: UInt64?
    private var recoveryStart: Double?
    private var pending: Recommendation?

    public init(profiles: [Profile], attemptID: UUID, applied: Settings, at now: Double) throws {
        guard now.isFinite, now >= 0 else { throw ValidationError.invalidTime }
        guard !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count else { throw ValidationError.invalidProfiles }
        for (index, profile) in profiles.enumerated() {
            guard !profile.id.isEmpty, profile.id.utf8.count <= 64,
                  profile.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  profile.width > 0, profile.height > 0, profile.width <= Int32.max, profile.height <= Int32.max,
                  profile.width.isMultiple(of: 2), profile.height.isMultiple(of: 2), profile.targetFPS == 30,
                  profile.minimumBitrate > 0, profile.maximumBitrate >= profile.minimumBitrate,
                  profile.maximumBitrate <= Int32.max else { throw ValidationError.invalidProfiles }
            if index > 0 {
                let prior = profiles[index - 1]
                guard profile.width >= prior.width, profile.height >= prior.height,
                      profile.width > prior.width || profile.height > prior.height,
                      profile.minimumBitrate >= prior.minimumBitrate, profile.maximumBitrate >= prior.maximumBitrate else {
                    throw ValidationError.invalidProfiles
                }
            }
        }
        guard Self.valid(applied, in: profiles) else { throw ValidationError.invalidSettings }
        self.profiles = profiles; self.attemptID = attemptID; self.applied = applied
        lastNow = now; appliedAt = now
    }

    /// Windows must be complete, nonoverlapping, 1–5 seconds long and received
    /// within 2 seconds of their end. Consecutive windows share exact boundaries.
    /// Invalid input clears recovery and pending recommendations; callers must
    /// treat rejected telemetry as unknown rather than retaining a healthy claim.
    public mutating func evaluate(_ window: Window, at now: Double) throws -> Decision {
        do {
            try recordTime(now)
            try validate(window, at: now)
        }
        catch { recoveryStart = nil; pending = nil; throw error }
        var reasons: [Reason] = []
        if let lastEnd, window.start != lastEnd {
            recoveryStart = nil
            reasons.append(.telemetryGap)
        }
        lastNow = now; lastEnd = window.end; lastSequence = window.sequence
        // Every new window supersedes earlier advice, even if it cannot establish health.
        pending = nil
        if window.connectivity == .disconnected {
            recoveryStart = nil
            return .init(state: .disconnected, reasons: reasons + [.disconnected], recommendation: nil)
        }
        var unknown = false
        func missing(_ reason: Reason) { unknown = true; reasons.append(reason) }
        if window.connectivity == .unknown { missing(.unknownConnectivity) }
        if window.capturedFreshFrames == nil { missing(.missingCapture) }
        if window.encodedFreshFrames == nil { missing(.missingEncoded) }
        var received: Int?
        if let receiver = window.receiver {
            if receiver.observedAt < window.end || now - receiver.observedAt > 2 { missing(.staleReceiver) }
            else { received = receiver.freshFrames }
        } else { missing(.missingReceiver) }
        if window.sourceLoss == nil { missing(.missingSourceLoss) }
        if window.meanQueueOccupancy == nil { missing(.missingQueue) }
        if window.usableVideoCapacity == nil { missing(.missingCapacity) }
        if window.thermalPressure == .unknown || window.workerPressure == .unknown { missing(.unknownPressure) }
        let duration = window.end - window.start
        let observedFPS = [window.capturedFreshFrames, window.encodedFreshFrames, received].compactMap { $0 }.map { Double($0) / duration }
        let stalled = observedFPS.contains(0)
        var unhealthy = false
        func decrease(_ reason: Reason) { unhealthy = true; reasons.append(reason) }
        if observedFPS.contains(where: { $0 < 24 }) { decrease(.freshFrameFloor) }
        if let loss = window.sourceLoss, Double(loss.lostFrames) / Double(loss.expectedFrames) > 0.01 { decrease(.sourceLoss) }
        if let queue = window.meanQueueOccupancy, queue >= 0.75 { decrease(.queuePressure) }
        if let capacity = window.usableVideoCapacity, capacity < Double(applied.videoBitrate) * 1.25 { decrease(.capacityHeadroom) }
        if window.thermalPressure == .elevated { decrease(.thermalPressure) }
        if window.workerPressure == .elevated { decrease(.workerPressure) }
        if stalled { reasons.append(.stalled) }
        let profileIndex = profiles.firstIndex { $0.id == applied.profileID }!
        if unhealthy {
            recoveryStart = nil
            let reduced = lowerSettings(profileIndex: profileIndex, capacity: window.usableVideoCapacity)
            if let reduced { pending = recommendation(reduced, for: window) }
            else { reasons.append(.minimumProfileInsufficient) }
            let state: State = stalled ? .stalled : unknown ? .unknown : reduced == nil ? .insufficient : .degraded
            return .init(state: state, reasons: reasons, recommendation: pending)
        }
        guard !unknown else {
            recoveryStart = nil
            return .init(state: .unknown, reasons: reasons, recommendation: nil)
        }
        // Recovery is stronger than the 24 fps floor: target cadence within 1%,
        // low queue occupancy, and headroom for the PROPOSED rate in every window.
        let higher = higherSettings(profileIndex: profileIndex)
        let qualified = observedFPS.allSatisfy { $0 >= 29.7 }
            && window.meanQueueOccupancy! < 0.5
            && higher.map { window.usableVideoCapacity! >= Double($0.videoBitrate) * 1.25 } == true
        if qualified {
            if recoveryStart == nil { recoveryStart = window.start }
            if window.end - recoveryStart! >= 30, let higher {
                pending = recommendation(higher, for: window)
                reasons.append(.recoveryQualified)
            }
        } else { recoveryStart = nil }
        return .init(state: .healthy, reasons: reasons, recommendation: pending)
    }

    /// Acknowledge only the latest recommendation. Pass nil for a failed change.
    /// Report actual supported settings, including platform clamping; recommendations
    /// never become truth merely because they were emitted. Successful application
    /// increments the revision, and subsequent windows must start after this time.
    public mutating func acknowledge(_ recommendation: Recommendation, applied actual: Settings?, at now: Double) throws {
        try recordTime(now)
        guard recommendation.attemptID == attemptID, recommendation.appliedRevision == appliedRevision,
              pending == recommendation else { throw ValidationError.staleRecommendation }
        guard now <= recommendation.validUntil else {
            recoveryStart = nil; pending = nil
            throw ValidationError.staleRecommendation
        }
        if let actual {
            guard Self.valid(actual, in: profiles), appliedRevision < UInt64.max else { throw ValidationError.invalidSettings }
            applied = actual; appliedRevision += 1; appliedAt = now
        }
        lastNow = now; recoveryStart = nil; pending = nil
    }

    private static func valid(_ settings: Settings, in profiles: [Profile]) -> Bool {
        profiles.contains { $0.id == settings.profileID && ($0.minimumBitrate...$0.maximumBitrate).contains(settings.videoBitrate) }
    }
    /// Finite caller time advances even when the rest of an input is rejected.
    /// Invalid clock values cannot change the watermark.
    private mutating func recordTime(_ now: Double) throws {
        guard now.isFinite, now >= lastNow else { throw ValidationError.invalidTime }
        lastNow = now
    }
    private func validate(_ window: Window, at now: Double) throws {
        guard window.attemptID == attemptID else { throw ValidationError.wrongAttempt }
        guard window.appliedRevision == appliedRevision else { throw ValidationError.wrongAppliedRevision }
        guard window.start.isFinite, window.end.isFinite, window.start >= appliedAt,
              (1...5).contains(window.end - window.start), window.end <= now else { throw ValidationError.invalidWindow }
        guard now - window.end <= 2 else { throw ValidationError.staleWindow }
        if let lastEnd, window.start < lastEnd { throw ValidationError.outOfOrder }
        if let lastSequence, window.sequence <= lastSequence { throw ValidationError.outOfOrder }
        guard [window.capturedFreshFrames, window.encodedFreshFrames, window.receiver?.freshFrames].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw ValidationError.invalidWindow
        }
        if let receiver = window.receiver {
            guard receiver.observedAt.isFinite, receiver.observedAt >= 0, receiver.observedAt <= now else { throw ValidationError.invalidWindow }
        }
        if let loss = window.sourceLoss {
            guard loss.expectedFrames > 0, loss.lostFrames >= 0, loss.lostFrames <= loss.expectedFrames else { throw ValidationError.invalidWindow }
        }
        if let queue = window.meanQueueOccupancy {
            guard queue.isFinite, (0...1).contains(queue) else { throw ValidationError.invalidWindow }
        }
        if let capacity = window.usableVideoCapacity {
            guard capacity.isFinite, capacity >= 0 else { throw ValidationError.invalidWindow }
        }
    }
    private func recommendation(_ settings: Settings, for window: Window) -> Recommendation {
        .init(attemptID: attemptID, windowSequence: window.sequence, appliedRevision: appliedRevision,
              validUntil: window.end + 2, settings: settings)
    }
    private func lowerSettings(profileIndex: Int, capacity: Double?) -> Settings? {
        let profile = profiles[profileIndex]
        if applied.videoBitrate > profile.minimumBitrate {
            // Target a 20% reduction, clamped to the profile minimum below.
            // Capacity is already net of audio/transport costs.
            let rate = min(Double(applied.videoBitrate) * 0.8, capacity.map { $0 / 1.25 } ?? .greatestFiniteMagnitude)
            return .init(profileID: profile.id, videoBitrate: max(profile.minimumBitrate, Int(rate)))
        }
        guard profileIndex > 0 else { return nil }
        let lower = profiles[profileIndex - 1]
        let rate = min(Double(lower.maximumBitrate), Double(applied.videoBitrate) * 0.8,
                       capacity.map { $0 / 1.25 } ?? .greatestFiniteMagnitude)
        return .init(profileID: lower.id, videoBitrate: max(lower.minimumBitrate, Int(rate)))
    }
    private func higherSettings(profileIndex: Int) -> Settings? {
        let profile = profiles[profileIndex]
        if applied.videoBitrate < profile.maximumBitrate {
            return .init(profileID: profile.id, videoBitrate: Int(min(Double(profile.maximumBitrate), (Double(applied.videoBitrate) * 1.1).rounded(.up))))
        }
        guard profileIndex + 1 < profiles.count else { return nil }
        let higher = profiles[profileIndex + 1]
        return .init(profileID: higher.id, videoBitrate: higher.minimumBitrate)
    }
}
