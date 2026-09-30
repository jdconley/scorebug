#if DEBUG
import Foundation
import ScorebugCore

/// Bounded successful Core acknowledgments, never policy or capacity evidence.
/// Owned by the quality session; closing freezes a detached export snapshot.
struct PublishingAppliedTransitionAudit {
    static let maximumRecords = 16
    static let maximumRecordBytes = 8192
    private let attemptID: UUID
    private let timingProfile: StreamingTimingProfile
    private var records: [[String: String]] = []
    private var closed = false
    private var overflow = false

    init(attemptID: UUID, timingProfile: StreamingTimingProfile) {
        self.attemptID = attemptID; self.timingProfile = timingProfile
    }
    mutating func append(_ fields: [String: String]) {
        guard !closed, !overflow else { return }
        guard records.count < Self.maximumRecords,
              let encoded = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              encoded.count <= Self.maximumRecordBytes else {
            // Preserve the contiguous prefix; never skip an omitted application
            // and resume with later records that appear to be complete evidence.
            overflow = true
            return
        }
        records.append(fields)
    }
    mutating func close() throws -> Data {
        closed = true
        return try checkpoint()
    }
    func checkpoint() throws -> Data {
        let timing: [String: Any] = ["formatVersion": 1, "scope": "ordinary-successful-applications",
            "profileId": timingProfile.rawValue, "decoderBudgetMs": timingProfile.decoderBudgetMs,
            "maximumCaptureWindowEvaluationAgeMs": timingProfile.maximumCaptureWindowEvaluationAgeMs,
            "maximumCompletedDecoderWindowReportAgeMs": timingProfile.maximumCompletedDecoderWindowReportAgeMs,
            "maximumCadenceDeliveryReportAgeMs": timingProfile.maximumCadenceDeliveryReportAgeMs,
            "decoderStallThresholdMs": timingProfile.decoderStallThresholdMs]
        return try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "scope": "successful applications only",
            "attemptID": attemptID.uuidString.lowercased(), "timingContract": timing,
            "maximumRecords": Self.maximumRecords, "maximumRecordBytes": Self.maximumRecordBytes,
            "closed": closed, "overflow": overflow, "records": records], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    /// Called only by the joined shutdown exporter. A failed write leaves missing
    /// evidence; it cannot overwrite a previous attempt artifact or claim a pass.
    static func persist(_ data: Data, attemptID: UUID) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug/QA", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("quality-transitions-\(attemptID.uuidString.lowercased()).json"),
                           options: .withoutOverwriting)
        } catch { /* Missing evidence is rejected by the offline verifier. */ }
    }
}

actor PublishingTransitionCheckpointWriter {
    let attemptID: UUID
    let directory: URL
    private var latestRevision: UInt64?
    private var latestData: Data?
    init(attemptID: UUID, directory: URL? = nil) {
        self.attemptID = attemptID
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug/QA", isDirectory: true)
    }
    func persist(_ data: Data, revision: UInt64) -> Bool {
        guard latestRevision.map({ revision > $0 }) ?? true,
              data.count <= PublishingAppliedTransitionAudit.maximumRecords * PublishingAppliedTransitionAudit.maximumRecordBytes + 4096 else { return false }
        // Actor jobs can arrive after a newer snapshot; never replace its prefix.
        if latestData == data { latestRevision = revision; return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("quality-transitions-\(attemptID.uuidString.lowercased())-checkpoint.json"), options: .atomic)
            latestRevision = revision; latestData = data
            return true
        } catch { return false } // A missing checkpoint is evidence failure, never a policy input.
    }
}
#endif
