import Foundation

/// Generation-scoped publishing capability. Keep in memory, separate from public media
/// snapshots; diagnostic descriptions deliberately exclude the credentialed URL.
public struct PublishAccess: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let gameId: String
    public let generation: Int
    public let recordingId: String
    public let publishUrl: URL
    public let serverTime: String
    public let publishingAttemptId: UUID?

    public var description: String { "PublishAccess(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

public enum RecordingStatus: String, Codable, Equatable, Sendable {
    case recording, stopped, interrupted
}

/// Wire dates remain ISO-8601 strings, preserving fractional seconds.
public struct RecordingAssociation: Codable, Equatable, Sendable {
    public var gameId: String
    public var recordingId: String
    public var deviceId: String
    public var startedAt: String
    public var updatedAt: String
    public var status: RecordingStatus
    public var sequence: Int

    public init(gameId: String, recordingId: String, deviceId: String, startedAt: String, updatedAt: String, status: RecordingStatus, sequence: Int) {
        self.gameId = gameId
        self.recordingId = recordingId
        self.deviceId = deviceId
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.status = status
        self.sequence = sequence
    }
}

public struct RecordingReport: Codable, Equatable, Sendable {
    public var recordingId: String
    public var sequence: Int
    public var status: RecordingStatus
    public var startedAt: String

    public init(recordingId: String, sequence: Int, status: RecordingStatus, startedAt: String) {
        self.recordingId = recordingId
        self.sequence = sequence
        self.status = status
        self.startedAt = startedAt
    }
}

/// Public identifiers select server-configured publishing resources. A start
/// command leaves `workerId`/`outputId` out (nil is not encoded) and the server
/// picks its worker; snapshots always carry the IDs it chose.
public struct BroadcastSelection: Codable, Equatable, Sendable {
    public var workerId: String?
    public var outputId: String?
    public var captureDeviceId: String
    public var recordingId: String

    public init(workerId: String? = nil, outputId: String? = nil, captureDeviceId: String, recordingId: String) {
        self.workerId = workerId
        self.outputId = outputId
        self.captureDeviceId = captureDeviceId
        self.recordingId = recordingId
    }

    /// Whether the server's selection is the one this request asked for. An
    /// unset worker or output accepts whatever the server picked.
    public func isMet(by actual: BroadcastSelection?) -> Bool {
        guard let actual else { return false }
        return actual.captureDeviceId == captureDeviceId && actual.recordingId == recordingId
            && (workerId == nil || actual.workerId == workerId)
            && (outputId == nil || actual.outputId == outputId)
    }
}

public struct MediaBroadcast: Codable, Equatable, Sendable {
    public var desired: BroadcastDesired
    public var generation: Int
    public var selection: BroadcastSelection?

    public init(desired: BroadcastDesired, generation: Int, selection: BroadcastSelection?) {
        self.desired = desired
        self.generation = generation
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey { case desired, generation, selection }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(desired, forKey: .desired)
        try container.encode(generation, forKey: .generation)
        try container.encode(selection, forKey: .selection)
    }
}

public struct MediaSnapshot: Codable, Equatable, Sendable {
    public var gameId: String
    public var recordings: [RecordingAssociation]
    public var broadcast: MediaBroadcast

    public init(gameId: String, recordings: [RecordingAssociation], broadcast: MediaBroadcast) {
        self.gameId = gameId
        self.recordings = recordings
        self.broadcast = broadcast
    }
}

public enum BroadcastOperation: Codable, Equatable, Sendable {
    case start(selection: BroadcastSelection)
    case stop

    private enum CodingKeys: String, CodingKey { case type, selection }
    private enum Kind: String, Codable { case start, stop }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .start: self = .start(selection: try container.decode(BroadcastSelection.self, forKey: .selection))
        case .stop: self = .stop
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .start(selection):
            try container.encode(Kind.start, forKey: .type)
            try container.encode(selection, forKey: .selection)
        case .stop:
            try container.encode(Kind.stop, forKey: .type)
        }
    }
}

public struct BroadcastCommand: Codable, Equatable, Sendable {
    public var commandId: String
    public var gameId: String
    public var expectedGeneration: Int
    public var issuedAt: String
    public var operation: BroadcastOperation

    public init(commandId: String, gameId: String, expectedGeneration: Int, issuedAt: String, operation: BroadcastOperation) {
        self.commandId = commandId
        self.gameId = gameId
        self.expectedGeneration = expectedGeneration
        self.issuedAt = issuedAt
        self.operation = operation
    }
}

public struct BroadcastOutcome: Codable, Equatable, Sendable {
    public var commandId: String
    public var accepted: Bool
    public var error: String?
    public var snapshot: MediaSnapshot

    public init(commandId: String, accepted: Bool, error: String?, snapshot: MediaSnapshot) {
        self.commandId = commandId
        self.accepted = accepted
        self.error = error
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey { case commandId, accepted, error, snapshot }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandId, forKey: .commandId)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(error, forKey: .error)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

public struct MediaSnapshotResponse: Codable, Equatable, Sendable {
    public var snapshot: MediaSnapshot
    public var serverTime: String

    public init(snapshot: MediaSnapshot, serverTime: String) {
        self.snapshot = snapshot
        self.serverTime = serverTime
    }
}

public struct RecordingReportResponse: Codable, Equatable, Sendable {
    public var recording: RecordingAssociation
    public var serverTime: String

    public init(recording: RecordingAssociation, serverTime: String) {
        self.recording = recording
        self.serverTime = serverTime
    }
}
