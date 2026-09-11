import BackgroundTasks
import SwiftUI
import UIKit
import WidgetKit

@main
struct SleeperWidgetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    handleDeepLink(url)
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

    /// A Live Activity or widget tap can only open its own app, so this app opens for a
    /// moment and, if the user prefers, hands off to Sleeper's league page. That's a
    /// universal link: it opens the Sleeper app when installed, and when it doesn't
    /// (`universalLinksOnly` refuses to fall back to Safari) we stay on our matchup.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == AppConfig.urlScheme else { return }
        let refreshHere = { Task { await model.refresh(force: true) } }
        guard SharedStore.tapOpensSleeper,
              let sleeperURL = AppConfig.sleeperMatchupURL(leagueId: SharedStore.leagueId) else {
            refreshHere()
            return
        }
        UIApplication.shared.open(sleeperURL, options: [.universalLinksOnly: true]) { opened in
            if !opened { refreshHere() }
        }
    }
}
