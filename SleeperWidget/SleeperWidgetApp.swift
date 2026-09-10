import BackgroundTasks
import SwiftUI
import WidgetKit

@main
struct SleeperWidgetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { _ in
                    // Deep links from the Live Activity or widget just bring the matchup forward.
                    Task { await model.refresh(force: true) }
                }
        }
        // Scene.onChange only offers the zero-argument action form; read the phase directly.
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                Task { await model.sceneDidBecomeActive() }
            case .background:
                model.sceneDidEnterBackground()
            default:
                break
            }
        }
        // Registers the BGAppRefreshTask launch handler; see BackgroundRefresh.perform().
        .backgroundTask(.appRefresh(AppConfig.backgroundRefreshTaskIdentifier)) {
            await BackgroundRefresh.perform()
        }
    }
}
