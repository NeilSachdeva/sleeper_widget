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
        static let relayAuthToken = "relay.authToken"
        static let relayRegisteredAt = "relay.registeredAt"
        static let lastRefresh = "refresh.last"
        static let autoStartSuppressedUntil = "liveActivity.suppressedUntil"
        static let tapOpensSleeper = "tap.opensSleeper"
    }

    /// Falls back to standard defaults if the App Group is misconfigured, so the app
    /// still runs (widgets just won't see the data) instead of crashing.
    static let defaults: UserDefaults = {
        guard isAppGroupAvailable, let shared = UserDefaults(suiteName: AppConfig.appGroupIdentifier) else {
            return .standard
        }
        return shared
    }()

    /// `UserDefaults(suiteName:)` never returns nil for a missing entitlement, but the
    /// container URL does, so that is the reliable check.
    static var isAppGroupAvailable: Bool { containerURL != nil }

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

    /// Tapping the Live Activity or a widget hands off to the Sleeper app (via its
    /// league page) instead of staying in this app. Default on.
    static var tapOpensSleeper: Bool {
        get { (defaults.object(forKey: Key.tapOpensSleeper) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Key.tapOpensSleeper) }
    }

    /// After the user taps Stop, auto-start stays off until this time (the end of the
    /// current game window) so the activity doesn't come straight back.
    static var autoStartSuppressedUntil: Date? {
        get { defaults.object(forKey: Key.autoStartSuppressedUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.autoStartSuppressedUntil) }
    }

    /// When the relay last accepted our registration; drives relay-first mode.
    static var relayRegisteredAt: Date? {
        get { defaults.object(forKey: Key.relayRegisteredAt) as? Date }
        set { defaults.set(newValue, forKey: Key.relayRegisteredAt) }
    }

    /// Base URL of the optional push relay in `server/` (e.g. https://relay.example.com).
    /// Falls back to `AppConfig.defaultRelayURL` when the user hasn't entered one.
    static var relayURL: URL? {
        get {
            guard let text = defaults.string(forKey: Key.relayURL), !text.isEmpty else {
                return AppConfig.defaultRelayURL
            }
            return URL(string: text)
        }
        set { defaults.set(newValue?.absoluteString, forKey: Key.relayURL) }
    }

    /// Whether the relay URL came from the user rather than the built-in default.
    static var hasCustomRelayURL: Bool {
        !(defaults.string(forKey: Key.relayURL) ?? "").isEmpty
    }

    /// Bearer token for a relay started with RELAY_AUTH_TOKEN; empty means none.
    /// Uses the built-in token while the built-in relay URL is in effect.
    static var relayAuthToken: String? {
        get {
            if let text = defaults.string(forKey: Key.relayAuthToken), !text.isEmpty { return text }
            return hasCustomRelayURL ? nil : AppConfig.defaultRelayAuthToken
        }
        set { defaults.set(newValue, forKey: Key.relayAuthToken) }
    }

    // MARK: Reset

    static func signOut() {
        for key in [Key.username, Key.userId, Key.userDisplayName, Key.userAvatarId,
                    Key.leagueId, Key.leagueName, Key.snapshot, Key.lastRefresh,
                    Key.liveActivityStartedManually, Key.autoStartSuppressedUntil, Key.relayRegisteredAt] {
            defaults.removeObject(forKey: key)
        }
    }
}
