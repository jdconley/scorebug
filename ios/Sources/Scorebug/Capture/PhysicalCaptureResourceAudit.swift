#if DEBUG && os(iOS) && !targetEnvironment(simulator)
import Darwin
import Foundation
import ScorebugMedia
import UIKit

/// Diagnostic scalars every ten seconds, outside the UI's published state.
/// First-hour history is bounded; encoder/probe ownership remains in its audit.
@MainActor final class PhysicalCaptureResourceAudit {
    private let source: IOSCameraCaptureSource
    private let recordingID: String
    private let profile: ArchiveProfile
    private let writer: PhysicalCaptureResourceWriter
    private let batteryMonitoringWasEnabled: Bool
    private var rows: [[String: Any]] = []
    private var nextSample = 0.0
    private var closed = false
    private var overflow = false
    init(source: IOSCameraCaptureSource, recordingID: String, profile: ArchiveProfile) {
        self.source = source; self.recordingID = recordingID; self.profile = profile
        writer = PhysicalCaptureResourceWriter(recordingID: recordingID)
        batteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        sample(phase: "preparing", force: true)
    }
    func sample(phase: String = "capturing", force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !closed, force || now >= nextSample else { return }
        nextSample = now + 10
        guard rows.count < 512 else { overflow = true; return }
        let counters = source.diagnosticSnapshot
        guard let data = try? JSONEncoder().encode(counters),
              let sourceObject = try? JSONSerialization.jsonObject(with: data) else { return }
        var row: [String: Any] = ["uptimeSeconds": now, "phase": phase,
            "processCPUSeconds": Double(clock()) / Double(CLOCKS_PER_SEC),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "batteryState": UIDevice.current.batteryState.rawValue,
            "batteryLevel": UIDevice.current.batteryLevel, "capture": sourceObject]
        row["physicalFootprintBytes"] = Self.physicalFootprint()
        rows.append(row)
        if force || rows.count % 3 == 0 { persist() }
    }
    func finish() async {
        sample(phase: "finalized", force: true)
        closed = true
        UIDevice.current.isBatteryMonitoringEnabled = batteryMonitoringWasEnabled
        if let data = encoded() { await writer.persist(data, sequence: rows.count + 1) }
    }
    private func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["formatVersion": 1, "recordingID": recordingID,
            "scope": "physical capture resources; diagnostic only", "closed": closed, "overflow": overflow,
            "archiveWidth": profile.width, "archiveHeight": profile.height, "archiveFPS": profile.framesPerSecond,
            "maximumRows": 512, "rows": rows], options: [.sortedKeys])
    }
    private func persist() {
        guard let data = encoded() else { return }
        let sequence = rows.count
        Task { await writer.persist(data, sequence: sequence) }
    }
    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

private actor PhysicalCaptureResourceWriter {
    private let recordingID: String
    private var latest = 0
    init(recordingID: String) { self.recordingID = recordingID }
    func persist(_ data: Data, sequence: Int) {
        guard sequence > latest else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug/QA", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("capture-resources-\(recordingID).json"), options: .atomic)
            latest = sequence
        } catch { /* Missing resource evidence cannot qualify a configuration. */ }
    }
}
#endif
