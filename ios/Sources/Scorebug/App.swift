import ScorebugCore
import ScorebugMedia
import SwiftUI

@main
struct ScorebugApp: App {
    @StateObject private var film: FilmModel
    @StateObject private var streaming: CaptureStreamingModel
    @StateObject private var scoring = ScoringModel()
    @StateObject private var phoneWatch: PhoneWatchModel
    @StateObject private var connectivity: WatchSetupConnectivity
    #if DEBUG
    private let recoveryLoopbackBridge: RecoveryLoopbackBridge?
    #endif
    init() {
        let connectivity = WatchSetupConnectivity()
        let forwarder = WatchRelayPhoneForwarder(timeout: 1.5, clientFactory: { MatchHTTPClient(endpoint: $0) })
        let bootstrap = WatchBootstrapPhoneForwarder(timeout: 1.5, clientFactory: { MatchHTTPClient(endpoint: $0) })
        let phoneWatch = PhoneWatchModel(storage: PhoneWatchRequestKeychain(),
            onRelayBindingChanged: { try? forwarder.updateBinding($0) },
            onBootstrapAuthorityChanged: { try? bootstrap.updateAuthority($0) },
            sendEnvelope: { try connectivity.sendEnvelope($0) })
        connectivity.noticeHandler = { [weak phoneWatch] in phoneWatch?.receive($0) }
        connectivity.peerChangedHandler = { [weak phoneWatch] in phoneWatch?.peerChanged() }
        connectivity.scoringRequestHandler = { [weak phoneWatch] data in
            guard let phoneWatch else { return Data() }
            // Retry a locked/unavailable Keychain read before each request.
            phoneWatch.restoreRelayAssociation()
            return await forwarder.forward(data)
        }
        connectivity.bootstrapRequestHandler = { [weak phoneWatch] data in
            guard let phoneWatch else { return Data() }
            phoneWatch.restoreRelayAssociation()
            return await bootstrap.forward(data)
        }
        phoneWatch.restoreRelayAssociation()
        connectivity.activate()
        _connectivity = StateObject(wrappedValue: connectivity)
        _phoneWatch = StateObject(wrappedValue: phoneWatch)
        let streaming = CaptureStreamingModel()
        #if DEBUG && targetEnvironment(simulator)
        let film = FilmModel(preferences: .standard, configuredSourceFactory: { profile in
            try SimulatorCaptureSource.make(environment: ProcessInfo.processInfo.environment,
                supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], profile: profile)
        }, sinkFactory: { directory, profile in
            try SimulatorCaptureSource.makeSink(directory: directory, profile: profile,
                environment: ProcessInfo.processInfo.environment)
        }, durationReader: { SimulatorCaptureSource.acceptedDuration($0) })
        #else
        let film = FilmModel(preferences: .standard, configuredSourceFactory: { IOSCameraCaptureSource(profile: $0) })
        #endif
        film.onCaptureChanged = { [weak streaming] context in streaming?.captureChanged(context, terminalStatus: nil) }
        film.onCaptureFinished = { [weak streaming] context, interrupted in streaming?.captureFinished(context, interrupted: interrupted) }
        _film = StateObject(wrappedValue: film)
        _streaming = StateObject(wrappedValue: streaming)
        #if DEBUG
        if let configuration = try? RecoveryLoopbackConfiguration(environment: ProcessInfo.processInfo.environment),
           let bridge = try? RecoveryLoopbackBridge(configuration: configuration) {
            recoveryLoopbackBridge = bridge
            bridge.start()
        } else { recoveryLoopbackBridge = nil }
        #endif
    }
    var body: some Scene {
        WindowGroup { ContentView(film: film, streaming: streaming, scoring: scoring, phoneWatch: phoneWatch, connectivity: connectivity) }
    }
}
