import Foundation

/// Identifiers shared by the app, the widget extension, and the optional push relay.
///
/// Change `bundleIdPrefix` in `project.yml` and the group identifier below together:
/// the App Group must be registered under your Apple Developer team (Xcode's
/// automatic signing does this the first time it sees the entitlement).
enum AppConfig {
    /// Name shown in the UI. The bundle display name in `spec/base.yml` should match.
    static let displayName = "Matchup Live"

    /// False in builds generated from `project-personal.yml` (free Personal Team),
    /// which cannot carry the Push Notifications entitlement: the activity is then
    /// started without a push token and the relay is left unused.
    static var supportsPush: Bool {
        #if PERSONAL_TEAM
        return false
        #else
        return true
        #endif
    }

    /// App Group used to share the latest matchup snapshot and settings between
    /// the app and the widget extension.
    static let appGroupIdentifier = "group.com.sleeperwidget.shared"

    /// Relay used when the user hasn't entered one in Settings. Set this to your
    /// deployed `server/` URL before distributing so testers get push updates
    /// without any setup; leave `nil` to require manual entry.
    static let defaultRelayURL: URL? = nil

    /// Bearer token paired with `defaultRelayURL` (the relay's RELAY_AUTH_TOKEN), if any.
    static let defaultRelayAuthToken: String? = nil

    /// Identifier for the BGAppRefreshTask that refreshes scores in the background.
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the app's Info.plist.
    static let backgroundRefreshTaskIdentifier = "com.sleeperwidget.refresh"

    /// Kind string for the lock-screen / home-screen matchup widget.
    static let matchupWidgetKind = "MatchupWidget"

    /// Custom URL scheme handled by the app (declared in Info.plist `CFBundleURLTypes`).
    static let urlScheme = "sleeperwidget"

    /// Deep link that opens the matchup screen from the Live Activity or a widget.
    static var matchupDeepLink: URL { URL(string: "\(urlScheme)://matchup")! }

    /// How long a Live Activity update is considered fresh before the system
    /// shows it as stale (greyed out) when no newer update arrived.
    static let liveActivityStaleInterval: TimeInterval = 30 * 60

    /// Minimum spacing between automatic foreground refreshes.
    static let foregroundRefreshInterval: TimeInterval = 45

    /// Sport tracked by this app. Sleeper also supports "nba", "lcs", etc.
    static let sport = "nfl"
}
