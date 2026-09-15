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
    init() {
        let connectivity = WatchSetupConnectivity()
        let forwarder = WatchRelayPhoneForwarder(timeout: 1.5, clientFactory: { MatchHTTPClient(endpoint: $0) })
        let phoneWatch = PhoneWatchModel(storage: PhoneWatchRequestKeychain(),
            onRelayBindingChanged: { try? forwarder.updateBinding($0) },
            sendEnvelope: { try connectivity.sendEnvelope($0) })
        connectivity.noticeHandler = { [weak phoneWatch] in phoneWatch?.receive($0) }
        connectivity.peerChangedHandler = { [weak phoneWatch] in phoneWatch?.peerChanged() }
        connectivity.scoringRequestHandler = { [weak phoneWatch] data in
            guard let phoneWatch else { return Data() }
            // Retry a locked/unavailable Keychain read before each request.
            phoneWatch.restoreRelayAssociation()
            return await forwarder.forward(data)
        }
        phoneWatch.restoreRelayAssociation()
        connectivity.activate()
        _connectivity = StateObject(wrappedValue: connectivity)
        _phoneWatch = StateObject(wrappedValue: phoneWatch)
        let streaming = CaptureStreamingModel()
        let film = FilmModel(sourceFactory: {
        #if DEBUG && targetEnvironment(simulator)
        return FixtureCameraSource(
            failAfterFrames: Int(ProcessInfo.processInfo.environment["SCOREBUG_FIXTURE_FAIL_AFTER"] ?? ""),
            motionFlag: ProcessInfo.processInfo.environment["SCOREBUG_TEST_MOTION_FIXTURE"])
        #else
        return IOSCameraCaptureSource()
        #endif
        })
        film.onCaptureChanged = { [weak streaming] context in streaming?.captureChanged(context, terminalStatus: nil) }
        film.onCaptureFinished = { [weak streaming] context, interrupted in streaming?.captureFinished(context, interrupted: interrupted) }
        _film = StateObject(wrappedValue: film)
        _streaming = StateObject(wrappedValue: streaming)
    }
    var body: some Scene {
        WindowGroup { ContentView(film: film, streaming: streaming, scoring: scoring, phoneWatch: phoneWatch, connectivity: connectivity) }
    }
}
