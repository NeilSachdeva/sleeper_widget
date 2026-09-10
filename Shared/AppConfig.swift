import Foundation

/// Identifiers shared by the app, the widget extension, and the optional push relay.
///
/// Change `bundleIdPrefix` in `project.yml` and the group identifier below together:
/// the App Group must be registered under your Apple Developer team (Xcode's
/// automatic signing does this the first time it sees the entitlement).
enum AppConfig {
    /// App Group used to share the latest matchup snapshot and settings between
    /// the app and the widget extension.
    static let appGroupIdentifier = "group.com.sleeperwidget.shared"

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
