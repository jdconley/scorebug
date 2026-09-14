import ScorebugMedia
import SwiftUI

@main
struct ScorebugApp: App {
    @StateObject private var film: FilmModel
    @StateObject private var streaming: CaptureStreamingModel
    init() {
        let streaming = CaptureStreamingModel()
        let film = FilmModel(sourceFactory: {
        #if DEBUG && targetEnvironment(simulator)
        return FixtureCameraSource(failAfterFrames: Int(ProcessInfo.processInfo.environment["SCOREBUG_FIXTURE_FAIL_AFTER"] ?? ""))
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
        WindowGroup { ContentView(film: film, streaming: streaming) }
    }
}
