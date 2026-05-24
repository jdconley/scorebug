import SwiftUI

@main
struct ScorebugApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var camera = CameraSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
