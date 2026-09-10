import ActivityKit
import Foundation
import Observation
import WidgetKit

/// Top-level app state: account, league, latest matchup, and the Live Activity.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case signedOut
        case choosingLeague
        case ready
    }

    private(set) var user: SleeperUser?
    private(set) var leagues: [SleeperLeague] = []
    private(set) var leagueId: String?
    private(set) var leagueName: String?
    private(set) var snapshot: MatchupSnapshot?
    private(set) var nflState: SleeperState?
    private(set) var lastRefresh: Date?
    var errorMessage: String?

    /// Number of `run` blocks in flight; `isBusy` stays true until the last one finishes.
    private(set) var busyCount = 0
    var isBusy: Bool { busyCount > 0 }

    let liveActivity = LiveActivityManager()

    @ObservationIgnored private let api = SleeperAPI()
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    /// Bumped whenever the account or league changes so a stale fetch can't land.
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var isSceneActive = false

    init() {
        if let userId = SharedStore.userId {
            user = SleeperUser(
                userId: userId,
                username: SharedStore.username,
                displayName: SharedStore.userDisplayName,
                avatar: SharedStore.userAvatarId
            )
        }
        leagueId = SharedStore.leagueId
        leagueName = SharedStore.leagueName
        snapshot = SharedStore.snapshot
        lastRefresh = SharedStore.lastRefresh
    }

    var stage: Stage {
        if user == nil { return .signedOut }
        if leagueId == nil { return .choosingLeague }
        return .ready
    }

    var isLiveActivityRunning: Bool { liveActivity.isRunning }

    // MARK: Account

    func signIn(username: String) async {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run {
            let found = try await self.api.user(trimmed)
            SharedStore.username = found.username ?? trimmed
            SharedStore.userId = found.userId
            SharedStore.userDisplayName = found.displayName
            SharedStore.userAvatarId = found.avatar
            self.user = found
            // Propagates a league-load failure instead of showing an empty picker.
            try await self.fetchLeagues(for: found)
        }
    }

    func signOut() {
        invalidateRefresh()
        let relayURL = SharedStore.relayURL
        Task {
            await liveActivity.end(immediately: true)
            await MatchupRefresher.dismissAllActivities()
            if let relayURL { await liveActivity.unregisterFromRelay(at: relayURL) }
        }
        SharedStore.signOut()
        user = nil
        leagues = []
        leagueId = nil
        leagueName = nil
        snapshot = nil
        lastRefresh = nil
        errorMessage = nil
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.matchupWidgetKind)
    }

    // MARK: Leagues

    func loadLeagues() async {
        guard let user else { return }
        await run { try await self.fetchLeagues(for: user) }
    }

    private func fetchLeagues(for user: SleeperUser) async throws {
        let state = try await api.state()
        nflState = state
        var found = try await api.leagues(userId: user.userId, season: state.currentLeagueSeason)
        if found.isEmpty, state.currentLeagueSeason != state.season {
            found = try await api.leagues(userId: user.userId, season: state.season)
        }
        leagues = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func select(league: SleeperLeague) async {
        invalidateRefresh()
        SharedStore.leagueId = league.leagueId
        SharedStore.leagueName = league.name
        leagueId = league.leagueId
        leagueName = league.name
        snapshot = nil
        SharedStore.snapshot = nil
        SharedStore.autoStartSuppressedUntil = nil
        await liveActivity.end(immediately: true)
        await MatchupRefresher.dismissAllActivities()
        await refresh(force: true)
    }

    func changeLeague() {
        invalidateRefresh()
        Task {
            await liveActivity.end(immediately: true)
            await MatchupRefresher.dismissAllActivities()
        }
        SharedStore.leagueId = nil
        SharedStore.leagueName = nil
        SharedStore.snapshot = nil
        leagueId = nil
        leagueName = nil
        snapshot = nil
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.matchupWidgetKind)
        Task { await loadLeagues() }
    }

    // MARK: Refresh

    /// Fetches the latest scores. Throttled unless `force` is set; concurrent callers share one request.
    func refresh(force: Bool = false) async {
        guard stage == .ready else { return }
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < AppConfig.foregroundRefreshInterval {
            return
        }
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run {
                let fresh = try await MatchupRefresher.refresh()
                // Ignore results that belong to a league or account we've since left.
                guard generation == self.refreshGeneration, fresh.leagueId == self.leagueId else { return }
                self.snapshot = fresh
                self.lastRefresh = fresh.updatedAt
                self.liveActivity.syncFromSystem()
                await self.liveActivity.reconcile(with: fresh)
            }
        }
        inFlightRefresh = task
        await task.value
        if inFlightRefresh == task { inFlightRefresh = nil }
    }

    /// Cancels any fetch in flight and stops polling; called before the account or league changes.
    private func invalidateRefresh() {
        refreshGeneration += 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        stopPolling()
    }

    // MARK: Scene lifecycle

    func sceneDidBecomeActive() async {
        isSceneActive = true
        await handleForeground()
        // A pass that started before the scene was active may have been cancelled by a
        // quick background/foreground bounce; make sure polling is on if games are on.
        if pollingTask == nil, stage == .ready { startPolling() }
    }

    func sceneDidEnterBackground() {
        isSceneActive = false
        foregroundTask?.cancel()
        stopPolling()
        BackgroundRefresh.schedule()
    }

    /// App came to the foreground: refresh, then auto-start the Live Activity if games are on.
    /// The scene-phase change and the matchup view's `task` both call this on a cold
    /// launch, so concurrent calls share one pass.
    func handleForeground() async {
        if let foregroundTask {
            await foregroundTask.value
            return
        }
        let task = Task { await self.performForeground() }
        foregroundTask = task
        await task.value
        if foregroundTask == task { foregroundTask = nil }
    }

    /// Cancellation (from `sceneDidEnterBackground`) is the signal to stop, not the
    /// scene flag: on a cold launch the matchup view's `task` can run before the scene
    /// phase reports active, and that pass must still auto-start the activity.
    private func performForeground() async {
        guard stage == .ready else { return }
        liveActivity.refreshAuthorization()
        await refresh(force: true)
        guard !Task.isCancelled, stage == .ready else { return }
        if let snapshot, !liveActivity.isRunning, MatchupRefresher.shouldAutoStart(snapshot) {
            try? await liveActivity.start(with: snapshot, manually: false)
        }
        await liveActivity.syncRelay()
        guard !Task.isCancelled, stage == .ready else { return }
        startPolling()
    }

    /// Refreshes every `foregroundRefreshInterval` while the matchup screen is visible
    /// and NFL games are on. Outside a game window scores can't change, so nothing polls;
    /// pull-to-refresh and the next foreground still fetch on demand.
    func startPolling() {
        pollingTask?.cancel()
        guard let week = snapshot?.week, GameWindow.current(week: week) != nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.foregroundRefreshInterval))
                guard let self, !Task.isCancelled, self.isSceneActive else { return }
                guard let week = self.snapshot?.week, GameWindow.current(week: week) != nil else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: Live Activity controls

    func startLiveActivity() async {
        guard let snapshot else {
            errorMessage = LiveActivityError.noMatchup.localizedDescription
            return
        }
        do {
            try await liveActivity.start(with: snapshot, manually: true)
            errorMessage = nil
        } catch let error as ActivityAuthorizationError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Plain-language explanations for the ActivityKit errors a user can actually fix.
    static func message(for error: ActivityAuthorizationError) -> String {
        switch error {
        case .denied:
            return "Live Activities are turned off for this app. Enable them in Settings › \(AppConfig.displayName)."
        case .targetMaximumExceeded, .globalMaximumExceeded:
            return "Too many Live Activities are running. Dismiss one from the Lock Screen and try again."
        case .visibility:
            return "Open the app to the foreground to start the Live Activity."
        case .unentitled, .unsupported, .unsupportedTarget:
            return "This build isn't set up for Live Activities (check NSSupportsLiveActivities in Info.plist)."
        default:
            return error.localizedDescription
        }
    }

    /// Ends the activity and keeps auto-start (app and relay) quiet until the current
    /// game window is over, so Stop actually sticks.
    func stopLiveActivity(now: Date = Date()) async {
        if let snapshot {
            let until = GameWindow.current(at: now, week: snapshot.week)?.end ?? now.addingTimeInterval(3 * 3600)
            SharedStore.autoStartSuppressedUntil = until
        }
        await liveActivity.end(with: snapshot, immediately: true)
    }

    // MARK: Relay

    func updateRelaySettings(url text: String, token: String) async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        SharedStore.relayAuthToken = trimmedToken.isEmpty ? nil : trimmedToken
        await updateRelayURL(text)
    }

    func updateRelayURL(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = SharedStore.relayURL
        if trimmed.isEmpty {
            SharedStore.relayURL = nil
            if let previous, previous != AppConfig.defaultRelayURL {
                await liveActivity.unregisterFromRelay(at: previous)
            }
            // Fall back to the built-in relay, if the build ships one.
            await liveActivity.syncRelay()
            return
        }
        guard let url = URL(string: trimmed), url.host != nil,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            errorMessage = "Relay URL must look like https://relay.example.com"
            return
        }
        SharedStore.relayURL = url
        await liveActivity.syncRelay()
        if let status = liveActivity.relayStatus, status.hasPrefix("Relay error") {
            errorMessage = status
        }
    }

    // MARK: Plumbing

    /// Runs `work`, tracking busy state and surfacing errors. Cancellation (including
    /// URLSession's `URLError.cancelled`) is silent. Returns true on success.
    @discardableResult
    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            try await work()
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}
