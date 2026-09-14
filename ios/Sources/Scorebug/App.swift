import ScorebugMedia
import SwiftUI

@main
struct ScorebugApp: App {
    @StateObject private var film = FilmModel(sourceFactory: {
        #if DEBUG && targetEnvironment(simulator)
        return FixtureCameraSource(failAfterFrames: Int(ProcessInfo.processInfo.environment["SCOREBUG_FIXTURE_FAIL_AFTER"] ?? ""))
        #else
        return IOSCameraCaptureSource()
        #endif
    })
    var body: some Scene {
        WindowGroup { ContentView(film: film) }
    }
}
