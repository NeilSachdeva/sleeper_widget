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
    private(set) var isBusy = false
    private(set) var lastRefresh: Date?
    var errorMessage: String?

    let liveActivity = LiveActivityManager()

    @ObservationIgnored private let api = SleeperAPI()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?

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
            await self.loadLeagues()
        }
    }

    func signOut() {
        refreshTask?.cancel()
        let relayURL = SharedStore.relayURL
        Task {
            await liveActivity.end(immediately: true)
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
        await run {
            let state = try await self.api.state()
            self.nflState = state
            var found = try await self.api.leagues(userId: user.userId, season: state.currentLeagueSeason)
            if found.isEmpty, state.currentLeagueSeason != state.season {
                found = try await self.api.leagues(userId: user.userId, season: state.season)
            }
            self.leagues = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func select(league: SleeperLeague) async {
        SharedStore.leagueId = league.leagueId
        SharedStore.leagueName = league.name
        leagueId = league.leagueId
        leagueName = league.name
        snapshot = nil
        SharedStore.snapshot = nil
        await liveActivity.end(immediately: true)
        await refresh(force: true)
    }

    func changeLeague() {
        Task { await liveActivity.end(immediately: true) }
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
        guard let user, let leagueId else { return }
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < AppConfig.foregroundRefreshInterval {
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run {
                let fresh = try await MatchupRefresher.refresh()
                self.snapshot = fresh
                self.lastRefresh = fresh.updatedAt
                self.liveActivity.syncFromSystem()
                await self.liveActivity.reconcile(with: fresh)
            }
        }
        inFlightRefresh = task
        await task.value
        inFlightRefresh = nil
    }

    /// App came to the foreground: refresh, then auto-start the Live Activity if games are on.
    func handleForeground() async {
        guard stage == .ready else { return }
        await refresh(force: true)
        if let snapshot, !liveActivity.isRunning, MatchupRefresher.shouldAutoStart(snapshot) {
            try? await liveActivity.start(with: snapshot, manually: false)
        }
        await liveActivity.syncRelay()
        startPolling()
    }

    /// Refreshes every `foregroundRefreshInterval` while the matchup screen is visible.
    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.foregroundRefreshInterval))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
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
            return "Live Activities are turned off for this app. Enable them in Settings › Sleeper Widget."
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

    func stopLiveActivity() async {
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
            if let previous { await liveActivity.unregisterFromRelay(at: previous) }
            return
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            errorMessage = "Relay URL must start with https://"
            return
        }
        SharedStore.relayURL = url
        await liveActivity.syncRelay()
    }

    // MARK: Plumbing

    private func run(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            errorMessage = nil
        } catch is CancellationError {
            // Ignore.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
