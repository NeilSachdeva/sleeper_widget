import Foundation

enum MatchupServiceError: LocalizedError, Equatable {
    case noRosterForUser
    case leagueNotFound

    var errorDescription: String? {
        switch self {
        case .noRosterForUser: return "You don't have a team in this league."
        case .leagueNotFound: return "That league could not be loaded."
        }
    }
}

/// Fetches everything needed for one matchup and turns it into a `MatchupSnapshot`.
/// Used by the app, the background refresh task, and the widget timeline provider.
struct MatchupService: Sendable {
    let api: SleeperAPI

    init(api: SleeperAPI = SleeperAPI()) {
        self.api = api
    }

    /// Loads the current week's matchup for `userId` in `leagueId`.
    func fetchSnapshot(userId: String, leagueId: String, now: Date = Date()) async throws -> MatchupSnapshot {
        let state = try await api.state()
        return try await fetchSnapshot(userId: userId, leagueId: leagueId, week: state.currentWeek, now: now)
    }

    /// Loads a specific week (handy for tests and for the final scores after a week ends).
    func fetchSnapshot(userId: String, leagueId: String, week: Int, now: Date = Date()) async throws -> MatchupSnapshot {
        async let league = api.league(leagueId)
        async let rosters = api.rosters(leagueId: leagueId)
        async let users = api.users(leagueId: leagueId)
        async let matchups = api.matchups(leagueId: leagueId, week: week)

        let (leagueValue, rosterValues, userValues, matchupValues) = try await (league, rosters, users, matchups)
        return try MatchupBuilder.build(
            userId: userId,
            league: leagueValue,
            week: week,
            rosters: rosterValues,
            users: userValues,
            matchups: matchupValues,
            now: now
        )
    }
}

/// Pure transformation from Sleeper responses to a snapshot. No I/O, so it is unit-testable.
enum MatchupBuilder {
    static func build(
        userId: String,
        league: SleeperLeague,
        week: Int,
        rosters: [SleeperRoster],
        users: [SleeperLeagueUser],
        matchups: [SleeperMatchup],
        now: Date = Date()
    ) throws -> MatchupSnapshot {
        guard let myRoster = rosters.first(where: { $0.isManaged(by: userId) }) else {
            throw MatchupServiceError.noRosterForUser
        }
        let usersById = Dictionary(users.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        let rostersById = Dictionary(rosters.map { ($0.rosterId, $0) }, uniquingKeysWith: { first, _ in first })
        let matchupsByRoster = Dictionary(matchups.map { ($0.rosterId, $0) }, uniquingKeysWith: { first, _ in first })

        let myMatchup = matchupsByRoster[myRoster.rosterId]
        let me = team(roster: myRoster, matchup: myMatchup, usersById: usersById)

        var opponent: MatchupSnapshot.Team?
        if let matchupId = myMatchup?.matchupId,
           let theirs = matchups.first(where: { $0.matchupId == matchupId && $0.rosterId != myRoster.rosterId }),
           let theirRoster = rostersById[theirs.rosterId] {
            opponent = team(roster: theirRoster, matchup: theirs, usersById: usersById)
        }

        // On a bye the phase still follows the week so "Final" appears once games end.
        let phase = GameWindow.phase(myPoints: me.points, opponentPoints: opponent?.points ?? 0, at: now)

        return MatchupSnapshot(
            leagueId: league.leagueId,
            leagueName: league.name,
            season: league.season,
            week: week,
            me: me,
            opponent: opponent,
            phase: phase,
            updatedAt: now
        )
    }

    private static func team(
        roster: SleeperRoster,
        matchup: SleeperMatchup?,
        usersById: [String: SleeperLeagueUser]
    ) -> MatchupSnapshot.Team {
        let owner = roster.ownerId.flatMap { usersById[$0] }
        return MatchupSnapshot.Team(
            rosterId: roster.rosterId,
            name: owner?.teamName ?? "Team \(roster.rosterId)",
            ownerName: owner?.displayName,
            avatarId: owner?.avatar,
            points: matchup?.effectivePoints ?? 0,
            record: roster.settings?.recordText
        )
    }
}
