import Foundation

/// Settings and the latest snapshot, stored in the App Group so both the app and
/// the widget extension can read them.
enum SharedStore {
    private enum Key {
        static let username = "sleeper.username"
        static let userId = "sleeper.userId"
        static let userDisplayName = "sleeper.userDisplayName"
        static let userAvatarId = "sleeper.userAvatarId"
        static let leagueId = "sleeper.leagueId"
        static let leagueName = "sleeper.leagueName"
        static let snapshot = "sleeper.snapshot"
        static let autoStartLiveActivity = "liveActivity.autoStart"
        static let liveActivityStartedManually = "liveActivity.manual"
        static let relayURL = "relay.url"
        static let lastRefresh = "refresh.last"
    }

    /// Falls back to standard defaults if the App Group is misconfigured, so the app
    /// still runs (widgets just won't see the data) instead of crashing.
    static let defaults: UserDefaults = {
        UserDefaults(suiteName: AppConfig.appGroupIdentifier) ?? .standard
    }()

    static var isAppGroupAvailable: Bool {
        UserDefaults(suiteName: AppConfig.appGroupIdentifier) != nil
    }

    /// Directory inside the App Group container for cached files (avatars).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)
    }

    // MARK: Account

    static var username: String? {
        get { defaults.string(forKey: Key.username) }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    static var userId: String? {
        get { defaults.string(forKey: Key.userId) }
        set { defaults.set(newValue, forKey: Key.userId) }
    }

    static var userDisplayName: String? {
        get { defaults.string(forKey: Key.userDisplayName) }
        set { defaults.set(newValue, forKey: Key.userDisplayName) }
    }

    static var userAvatarId: String? {
        get { defaults.string(forKey: Key.userAvatarId) }
        set { defaults.set(newValue, forKey: Key.userAvatarId) }
    }

    static var leagueId: String? {
        get { defaults.string(forKey: Key.leagueId) }
        set { defaults.set(newValue, forKey: Key.leagueId) }
    }

    static var leagueName: String? {
        get { defaults.string(forKey: Key.leagueName) }
        set { defaults.set(newValue, forKey: Key.leagueName) }
    }

    static var isConfigured: Bool { userId != nil && leagueId != nil }

    // MARK: Snapshot

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static var snapshot: MatchupSnapshot? {
        get {
            guard let data = defaults.data(forKey: Key.snapshot) else { return nil }
            return try? decoder.decode(MatchupSnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.snapshot)
            } else {
                defaults.removeObject(forKey: Key.snapshot)
            }
        }
    }

    static var lastRefresh: Date? {
        get { defaults.object(forKey: Key.lastRefresh) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRefresh) }
    }

    // MARK: Live Activity preferences

    /// Start a Live Activity automatically when the app comes to the foreground during a game window.
    static var autoStartLiveActivity: Bool {
        get { (defaults.object(forKey: Key.autoStartLiveActivity) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.autoStartLiveActivity) }
    }

    /// Whether the current activity was started by the user (never auto-ended) or automatically.
    static var liveActivityStartedManually: Bool {
        get { defaults.bool(forKey: Key.liveActivityStartedManually) }
        set { defaults.set(newValue, forKey: Key.liveActivityStartedManually) }
    }

    /// Base URL of the optional push relay in `server/` (e.g. https://relay.example.com).
    static var relayURL: URL? {
        get {
            guard let text = defaults.string(forKey: Key.relayURL), !text.isEmpty else { return nil }
            return URL(string: text)
        }
        set { defaults.set(newValue?.absoluteString, forKey: Key.relayURL) }
    }

    // MARK: Reset

    static func signOut() {
        for key in [Key.username, Key.userId, Key.userDisplayName, Key.userAvatarId,
                    Key.leagueId, Key.leagueName, Key.snapshot, Key.lastRefresh,
                    Key.liveActivityStartedManually] {
            defaults.removeObject(forKey: key)
        }
    }
}
