import AppIntents
import Foundation

/// Backs the refresh button inside the Live Activity. The system runs it in the app's
/// process with background runtime, so scores can be refreshed without unlocking or
/// opening the app. Must compile into both the app and the widget extension.
struct RefreshMatchupIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Refresh Matchup"

    func perform() async throws -> some IntentResult {
        do {
            let snapshot = try await MatchupRefresher.refresh()
            await MatchupRefresher.applyToActivities(snapshot)
        } catch {
            // A failed refresh just leaves the last scores on screen.
        }
        return .result()
    }
}
