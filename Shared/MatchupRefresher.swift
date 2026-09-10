import ActivityKit
import Foundation
import WidgetKit

/// One place for "fetch the latest matchup and push it everywhere": used by the app's
/// refresh loop, the background task, and the Live Activity's refresh button.
enum MatchupRefresher {
    /// Fetches the current snapshot, stores it in the App Group, caches avatars, and
    /// reloads the widget timeline. Throws when the account isn't configured or the
    /// network fails.
    @discardableResult
    static func refresh(now: Date = Date()) async throws -> MatchupSnapshot {
        guard let userId = SharedStore.userId, let leagueId = SharedStore.leagueId else {
            throw MatchupServiceError.leagueNotFound
        }
        let snapshot = try await MatchupService().fetchSnapshot(userId: userId, leagueId: leagueId, now: now)
        // The user may have switched leagues or signed out while this was in flight.
        guard SharedStore.userId == userId, SharedStore.leagueId == leagueId else { throw CancellationError() }
        SharedStore.snapshot = snapshot
        SharedStore.lastRefresh = snapshot.updatedAt
        await AvatarCache.prefetch(for: snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.matchupWidgetKind)
        return snapshot
    }

    // MARK: Live Activity policy

    /// Automatic activities live for one game window (well inside Apple's 8-hour cap);
    /// manual ones until the week's games are final.
    static func shouldKeepActivityAlive(_ snapshot: MatchupSnapshot, manual: Bool, now: Date = Date()) -> Bool {
        guard snapshot.phase != .final else { return false }
        return manual || GameWindow.current(at: now, week: snapshot.week) != nil
    }

    /// Snapshots older than this are not trusted to start an activity (offline launch
    /// with last week's data must not pin last week's opponent as LIVE).
    static let autoStartFreshness: TimeInterval = 10 * 60

    /// Whether the app should start an activity on its own right now.
    static func shouldAutoStart(_ snapshot: MatchupSnapshot, now: Date = Date()) -> Bool {
        guard SharedStore.autoStartLiveActivity, !snapshot.isBye, snapshot.phase != .final else { return false }
        guard now.timeIntervalSince(snapshot.updatedAt) < autoStartFreshness else { return false }
        if let until = SharedStore.autoStartSuppressedUntil, until > now { return false }
        return GameWindow.current(at: now, week: snapshot.week) != nil
    }

    /// Relay-first mode: while the relay has accepted our registration recently, it
    /// polls Sleeper and pushes every change, so the phone schedules no background work.
    static let relayFirstGrace: TimeInterval = 24 * 3600

    static func isRelayHandlingUpdates(now: Date = Date()) -> Bool {
        guard SharedStore.relayURL != nil, let registered = SharedStore.relayRegisteredAt else { return false }
        return now.timeIntervalSince(registered) < relayFirstGrace
    }

    static func activityContent(for snapshot: MatchupSnapshot, now: Date = Date()) -> ActivityContent<MatchupActivityAttributes.ContentState> {
        let inWindow = GameWindow.current(at: now, week: snapshot.week) != nil
        return ActivityContent(
            state: snapshot.activityContentState,
            staleDate: now.addingTimeInterval(AppConfig.liveActivityStaleInterval),
            relevanceScore: inWindow ? 100 : 50
        )
    }

    /// Updates or ends every running activity of ours to match `snapshot`. Safe to call
    /// from the background (only `Activity.request` needs the foreground).
    static func applyToActivities(_ snapshot: MatchupSnapshot, now: Date = Date()) async {
        let manual = SharedStore.liveActivityStartedManually
        for activity in Activity<MatchupActivityAttributes>.activities {
            switch activity.activityState {
            case .active, .stale:
                guard snapshot.matches(activity.attributes) else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                if shouldKeepActivityAlive(snapshot, manual: manual, now: now) {
                    await activity.update(activityContent(for: snapshot, now: now))
                } else {
                    await activity.end(activityContent(for: snapshot, now: now), dismissalPolicy: .default)
                }
            default:
                continue
            }
        }
    }

    /// Removes every activity of ours from the Lock Screen right away.
    static func dismissAllActivities() async {
        for activity in Activity<MatchupActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
