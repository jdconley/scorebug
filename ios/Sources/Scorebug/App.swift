import ScorebugCore
import ScorebugMedia
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Portrait everywhere except the live filming screen.
    static var orientations: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : Self.orientations
    }
}

@main
struct ScorebugApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app: AppModel
    @StateObject private var film: FilmModel
    @StateObject private var streaming: CaptureStreamingModel
    @StateObject private var watch = PhoneWatchLink()
    #if DEBUG
    private let recoveryLoopbackBridge: RecoveryLoopbackBridge?
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Simulator QA only: start from a fresh install state.
        if ProcessInfo.processInfo.environment["SCOREBUG_TEST_RESET"] == "1" {
            let keychain = KeychainStore()
            for key in [StoreKey.server, StoreKey.session, StoreKey.enrollmentDeviceId] { try? keychain.set(nil, for: key) }
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        }
        #endif
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
        _app = StateObject(wrappedValue: AppModel(store: KeychainStore(), preferences: AppPreferences(),
                                                  deviceName: { UIDevice.current.name }))
        #if DEBUG
        if let configuration = try? RecoveryLoopbackConfiguration(environment: ProcessInfo.processInfo.environment),
           let bridge = try? RecoveryLoopbackBridge(configuration: configuration) {
            recoveryLoopbackBridge = bridge
            bridge.start()
        } else { recoveryLoopbackBridge = nil }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app, film: film, streaming: streaming, watch: watch)
                .preferredColorScheme(.dark)
                .tint(Theme.text)
                .onAppear {
                    watch.activate()
                    #if DEBUG
                    // Simulator QA: SCOREBUG_TEST_LINK opens a setup or invite link on launch.
                    if let link = ProcessInfo.processInfo.environment["SCOREBUG_TEST_LINK"] { app.open(link) }
                    #endif
                }
        }
    }
}
