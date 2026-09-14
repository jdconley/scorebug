import ScorebugCore
import SwiftUI
import WatchKit

@main
@MainActor
struct ScorebugWatchApp: App {
    @StateObject private var model: WatchScoringModel
    @StateObject private var connectivity: WatchSetupConnectivity
    private let fixture: WatchPairingEnvelope?

    init() {
        let connectivity = WatchSetupConnectivity()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scorebug", isDirectory: true)
        let pending = JSONFilePendingCommandStore(url: directory.appendingPathComponent("pending-command.json"))
        let fixture = Self.simulatorSetup()
        let coordinator = WatchSetupCoordinator(storage: WatchSetupKeychain(), scoringOutbox: pending,
            newDeviceId: { fixture?.offer.watchDeviceId ?? UUID().uuidString })
        _connectivity = StateObject(wrappedValue: connectivity)
        _model = StateObject(wrappedValue: WatchScoringModel(setupCoordinator: coordinator, pendingStore: pending,
            onNotice: { try? connectivity.sendNotice($0) },
            acknowledgmentHaptic: { WKInterfaceDevice.current().play(.success) }))
        self.fixture = fixture
    }
    var body: some Scene {
        WindowGroup { WatchRootView(model: model, connectivity: connectivity, fixture: fixture) }
    }
    private static func simulatorSetup() -> WatchPairingEnvelope? {
        #if DEBUG && targetEnvironment(simulator)
        guard let text = ProcessInfo.processInfo.environment["SCOREBUG_TEST_WATCH_SETUP"],
              let envelope = try? WatchCompanionCodec.decodeEnvelope(Data(text.utf8)),
              URLComponents(string: envelope.endpoint)?.host == "127.0.0.1" else { return nil }
        return envelope
        #else
        return nil
        #endif
    }
}

private struct WatchRootView: View {
    @ObservedObject var model: WatchScoringModel
    @ObservedObject var connectivity: WatchSetupConnectivity
    let fixture: WatchPairingEnvelope?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        WatchScoringView(model: model)
            .task(id: phase) {
                await model.suspend()
                guard !Task.isCancelled, phase == .active else { return }
                connectivity.activate()
                await model.wake()
                var delivered: WatchPairingEnvelope?
                while !Task.isCancelled {
                    if let envelope = connectivity.latestEnvelope ?? fixture, envelope != delivered {
                        await model.receive(envelope)
                        delivered = envelope
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if model.pending || model.phase == .pending { await model.refresh() }
                    else { await model.poll() }
                }
            }
    }
}
