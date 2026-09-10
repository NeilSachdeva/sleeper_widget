import ActivityKit
import Foundation
import Observation

enum LiveActivityError: LocalizedError {
    case disabled
    case noMatchup

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Live Activities are turned off for this app. Enable them in Settings › \(AppConfig.displayName)."
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
    /// Mirrors Settings › app › Live Activities; refreshed live via `activityEnablementUpdates`.
    private(set) var areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var pushToStartTask: Task<Void, Never>?
    @ObservationIgnored private var newActivitiesTask: Task<Void, Never>?
    @ObservationIgnored private var enablementTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Error>?
    @ObservationIgnored private var relaySyncTask: Task<Void, Never>?

    init() {
        adoptExistingActivity()
        observePushToStartToken()
        observeNewActivities()
        observeEnablement()
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

    /// Re-reads the Settings toggle (also kept current by `observeEnablement`).
    func refreshAuthorization() {
        areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: Lifecycle

    /// Starts (or refreshes) the Live Activity for `snapshot`. Concurrent callers (a cold
    /// launch runs the foreground path twice) share one `Activity.request`.
    func start(with snapshot: MatchupSnapshot, manually: Bool) async throws {
        if let startTask {
            _ = try? await startTask.value
            if let activity, isRunning, snapshot.matches(activity.attributes) {
                await markManualIfNeeded(manually)
                return
            }
        }
        let task = Task { try await self.performStart(with: snapshot, manually: manually) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func performStart(with snapshot: MatchupSnapshot, manually: Bool) async throws {
        refreshAuthorization()
        guard areActivitiesEnabled else { throw LiveActivityError.disabled }

        if let activity, isRunning {
            if snapshot.matches(activity.attributes) {
                await update(with: snapshot)
                await markManualIfNeeded(manually)
                return
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // Clear cards left over from earlier activities (ended by the 8-hour limit or a
        // previous window) so the Lock Screen shows only the new one.
        await MatchupRefresher.dismissAllActivities()

        // Something else (a push-to-start, the other foreground call) may have started
        // a matching activity while we were dismissing; adopt it instead of doubling up.
        if let running = Activity<MatchupActivityAttributes>.activities.first(where: {
            $0.activityState == .active && snapshot.matches($0.attributes)
        }) {
            SharedStore.liveActivityStartedManually = manually
            adopt(running)
            return
        }

        let content = MatchupRefresher.activityContent(for: snapshot)
        let pushType: PushType? = AppConfig.supportsPush ? PushType.token : nil
        let started = try Activity.request(
            attributes: snapshot.activityAttributes,
            content: content,
            pushType: pushType
        )
        SharedStore.liveActivityStartedManually = manually
        SharedStore.autoStartSuppressedUntil = nil
        adopt(started)
    }

    private func markManualIfNeeded(_ manually: Bool) async {
        guard manually, !SharedStore.liveActivityStartedManually else { return }
        SharedStore.liveActivityStartedManually = true
        SharedStore.autoStartSuppressedUntil = nil
        await syncRelay()
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
                    guard self.activity?.id == activity.id else { return }
                    // This task is the state observer itself: let it finish rather than
                    // cancelling it, or the relay call below dies with URLError.cancelled.
                    self.clearActivity(cancelStateObserver: false)
                    Task { await self.syncRelay() }
                    return
                default:
                    break
                }
            }
        }
        Task { await syncRelay() }
    }

    private func clearActivity(cancelStateObserver: Bool = true) {
        tokenTask?.cancel()
        tokenTask = nil
        if cancelStateObserver { stateTask?.cancel() }
        stateTask = nil
        activity = nil
        activityPushToken = nil
        SharedStore.liveActivityStartedManually = false
    }

    /// Push-to-start tokens (iOS 17.2+) let the relay start the activity remotely.
    private func observePushToStartToken() {
        guard AppConfig.supportsPush else { return }
        pushToStartTask = Task { [weak self] in
            for await token in Activity<MatchupActivityAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled else { return }
                self.pushToStartToken = token.hexString
                await self.syncRelay()
            }
        }
    }

    /// Activities started remotely (push-to-start) show up here; adopt them so we
    /// get their update tokens. Activities we started ourselves are already adopted.
    private func observeNewActivities() {
        newActivitiesTask = Task { [weak self] in
            for await started in Activity<MatchupActivityAttributes>.activityUpdates {
                guard let self, !Task.isCancelled else { return }
                guard self.activity?.id != started.id else { continue }
                if self.activity == nil || !self.isRunning {
                    self.adopt(started)
                }
            }
        }
    }

    /// Keeps `areActivitiesEnabled` in step with the Settings toggle.
    private func observeEnablement() {
        enablementTask = Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard let self, !Task.isCancelled else { return }
                self.areActivitiesEnabled = enabled
            }
        }
    }

    // MARK: Relay

    /// Sends current tokens to the relay, if one is configured. Calls are serialized so
    /// the registration the relay ends up with is always the most recent one.
    func syncRelay() async {
        let previous = relaySyncTask
        let task = Task {
            await previous?.value
            await self.performRelaySync()
        }
        relaySyncTask = task
        await task.value
        if relaySyncTask == task { relaySyncTask = nil }
    }

    private func performRelaySync() async {
        guard AppConfig.supportsPush else {
            relayStatus = SharedStore.relayURL == nil ? nil : "Push isn't available in Personal Team builds"
            return
        }
        guard let relayURL = SharedStore.relayURL else {
            relayStatus = nil
            return
        }
        guard let userId = SharedStore.userId, let leagueId = SharedStore.leagueId else { return }
        let suppressedUntil = SharedStore.autoStartSuppressedUntil.flatMap { until in
            until > Date() ? ISO8601DateFormatter().string(from: until) : nil
        }
        let registration = RelayClient.Registration(
            installId: RelayClient.installId,
            userId: userId,
            leagueId: leagueId,
            pushToStartToken: pushToStartToken,
            activityToken: isRunning ? activityPushToken : nil,
            activityId: isRunning ? activity?.id : nil,
            environment: RelayClient.apnsEnvironment,
            timeZone: TimeZone.current.identifier,
            startedManually: isRunning && SharedStore.liveActivityStartedManually,
            suppressAutoStartUntil: suppressedUntil
        )
        do {
            try await relayClient(for: relayURL).register(registration)
            SharedStore.relayRegisteredAt = Date()
            relayStatus = "Registered with relay"
        } catch {
            relayStatus = "Relay error: \(error.localizedDescription)"
        }
    }

    /// Removes this install from the relay (sign out / relay URL cleared).
    func unregisterFromRelay(at relayURL: URL) async {
        try? await relayClient(for: relayURL).unregister(installId: RelayClient.installId)
        SharedStore.relayRegisteredAt = nil
        relayStatus = nil
    }

    private func relayClient(for relayURL: URL) -> RelayClient {
        RelayClient(baseURL: relayURL, authToken: SharedStore.relayAuthToken)
    }
}
