import BackgroundTasks
import Foundation

/// Opportunistic background score updates. iOS decides when (typically every
/// 15–60 minutes for apps the user opens regularly), so treat this as a bonus on
/// top of foreground refreshes and the optional push relay.
enum BackgroundRefresh {
    /// Asks the system for a refresh; sooner during a game window.
    static func schedule(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.backgroundRefreshTaskIdentifier)
        let week = SharedStore.snapshot?.week ?? 1
        let interval: TimeInterval = GameWindow.current(at: now, week: week) != nil ? 15 * 60 : 60 * 60
        request.earliestBeginDate = now.addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common in the simulator or when background refresh is disabled; nothing to do.
            #if DEBUG
            print("BackgroundRefresh: could not schedule (\(error))")
            #endif
        }
    }

    /// Runs inside the background task: refresh the snapshot, update any running
    /// Live Activity, reload widgets, and re-arm.
    static func perform() async {
        defer { schedule() }
        guard SharedStore.isConfigured else { return }

        do {
            let snapshot = try await MatchupRefresher.refresh()
            await MatchupRefresher.applyToActivities(snapshot)
        } catch {
            #if DEBUG
            print("BackgroundRefresh: refresh failed (\(error))")
            #endif
        }
    }
}
