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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.handleForeground() }
            case .background:
                model.stopPolling()
                BackgroundRefresh.schedule()
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
