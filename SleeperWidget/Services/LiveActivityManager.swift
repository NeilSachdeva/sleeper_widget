import ActivityKit
import Foundation
import Observation

enum LiveActivityError: LocalizedError {
    case disabled
    case noMatchup

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Live Activities are turned off for this app. Enable them in Settings › Sleeper Widget."
        case .noMatchup:
            return "Load a matchup before starting a Live Activity."
        }
    }
}

/// Owns the matchup Live Activity: starting, updating, ending, and keeping push
/// tokens registered with the optional relay.
@MainActor
@Observable
final class LiveActivityManager {
    private(set) var activity: Activity<MatchupActivityAttributes>?
    private(set) var pushToStartToken: String?
    private(set) var activityPushToken: String?
    private(set) var relayStatus: String?

    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var pushToStartTask: Task<Void, Never>?
    @ObservationIgnored private var newActivitiesTask: Task<Void, Never>?

    init() {
        adoptExistingActivity()
        observePushToStartToken()
        observeNewActivities()
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Whether the user allows the higher push budget (Settings › app › Live Activities › More Frequent Updates).
    var frequentPushesEnabled: Bool {
        ActivityAuthorizationInfo().frequentPushesEnabled
    }

    var isRunning: Bool {
        guard let activity else { return false }
        switch activity.activityState {
        case .active, .stale: return true
        default: return false
        }
    }

    // MARK: Lifecycle

    /// Starts (or refreshes) the Live Activity for `snapshot`.
    func start(with snapshot: MatchupSnapshot, manually: Bool) async throws {
        guard areActivitiesEnabled else { throw LiveActivityError.disabled }

        if let activity, isRunning {
            if snapshot.matches(activity.attributes) {
                await update(with: snapshot)
                if manually, !SharedStore.liveActivityStartedManually {
                    SharedStore.liveActivityStartedManually = true
                    await syncRelay()
                }
                return
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // Clear cards left over from earlier activities (ended by the 8-hour limit or a
        // previous window) so the Lock Screen shows only the new one.
        await MatchupRefresher.dismissAllActivities()

        let content = MatchupRefresher.activityContent(for: snapshot)
        let started = try Activity.request(
            attributes: snapshot.activityAttributes,
            content: content,
            pushType: .token
        )
        SharedStore.liveActivityStartedManually = manually
        adopt(started)
    }

    /// Pushes new scores into the running activity.
    func update(with snapshot: MatchupSnapshot) async {
        guard let activity, isRunning, snapshot.matches(activity.attributes) else { return }
        await activity.update(MatchupRefresher.activityContent(for: snapshot))
    }

    /// Ends the activity. It stays on the Lock Screen briefly with the final score.
    func end(with snapshot: MatchupSnapshot? = nil, immediately: Bool = false) async {
        guard let activity else { return }
        let content = snapshot.map { MatchupRefresher.activityContent(for: $0) }
        await activity.end(content, dismissalPolicy: immediately ? .immediate : .default)
        clearActivity()
        await syncRelay()
    }

    /// Called after every refresh: keeps the activity current, or ends an automatic
    /// one once the game window is over.
    func reconcile(with snapshot: MatchupSnapshot, now: Date = Date()) async {
        guard isRunning else { return }
        guard let activity, snapshot.matches(activity.attributes) else {
            await end(immediately: true)
            return
        }
        if MatchupRefresher.shouldKeepActivityAlive(snapshot, manual: SharedStore.liveActivityStartedManually, now: now) {
            await update(with: snapshot)
        } else {
            await end(with: snapshot)
        }
    }

    /// Re-reads `Activity.activities` after something outside this object (the
    /// background task, the refresh intent, a push) changed them.
    func syncFromSystem() {
        if let activity, activity.activityState == .active || activity.activityState == .stale { return }
        clearActivity()
        adoptExistingActivity()
    }

    // MARK: Helpers

    private func adoptExistingActivity() {
        let existing = Activity<MatchupActivityAttributes>.activities
        if let running = existing.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            adopt(running)
        }
    }

    private func adopt(_ activity: Activity<MatchupActivityAttributes>) {
        tokenTask?.cancel()
        stateTask?.cancel()
        self.activity = activity
        activityPushToken = activity.pushToken?.hexString

        tokenTask = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.activityPushToken = token.hexString
                await self.syncRelay()
            }
        }
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                switch state {
                case .ended, .dismissed:
                    if self.activity?.id == activity.id {
                        self.clearActivity()
                        await self.syncRelay()
                    }
                default:
                    break
                }
            }
        }
        Task { await syncRelay() }
    }

    private func clearActivity() {
        tokenTask?.cancel()
        stateTask?.cancel()
        tokenTask = nil
        stateTask = nil
        activity = nil
        activityPushToken = nil
        SharedStore.liveActivityStartedManually = false
    }

    /// Push-to-start tokens (iOS 17.2+) let the relay start the activity remotely.
    private func observePushToStartToken() {
        pushToStartTask = Task { [weak self] in
            for await token in Activity<MatchupActivityAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.pushToStartToken = token.hexString
                await self.syncRelay()
            }
        }
    }

    /// Activities started remotely (push-to-start) show up here; adopt them so we
    /// get their update tokens.
    private func observeNewActivities() {
        newActivitiesTask = Task { [weak self] in
            for await started in Activity<MatchupActivityAttributes>.activityUpdates {
                guard let self, !Task.isCancelled else { return }
                if self.activity == nil || self.activity?.id == started.id || !self.isRunning {
                    self.adopt(started)
                }
            }
        }
    }

    // MARK: Relay

    /// Sends current tokens to the relay, if one is configured.
    func syncRelay() async {
        guard let relayURL = SharedStore.relayURL else {
            relayStatus = nil
            return
        }
        guard let userId = SharedStore.userId, let leagueId = SharedStore.leagueId else { return }
        let registration = RelayClient.Registration(
            installId: RelayClient.installId,
            userId: userId,
            leagueId: leagueId,
            pushToStartToken: pushToStartToken,
            activityToken: isRunning ? activityPushToken : nil,
            activityId: isRunning ? activity?.id : nil,
            environment: RelayClient.apnsEnvironment,
            timeZone: TimeZone.current.identifier,
            startedManually: isRunning && SharedStore.liveActivityStartedManually
        )
        do {
            try await relayClient(for: relayURL).register(registration)
            relayStatus = "Registered with relay"
        } catch {
            relayStatus = "Relay error: \(error.localizedDescription)"
        }
    }

    /// Removes this install from the relay (sign out / relay URL cleared).
    func unregisterFromRelay(at relayURL: URL) async {
        try? await relayClient(for: relayURL).unregister(installId: RelayClient.installId)
        relayStatus = nil
    }

    private func relayClient(for relayURL: URL) -> RelayClient {
        RelayClient(baseURL: relayURL, authToken: SharedStore.relayAuthToken)
    }
}
