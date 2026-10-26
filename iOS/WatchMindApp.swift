import SwiftUI

@main
struct WatchMindApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .onChange(of: scenePhase) { _, phase in model.setForeground(phase == .active) }
        }
    }
}
