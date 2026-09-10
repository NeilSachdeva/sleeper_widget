import XCTest
@testable import SleeperWidget

final class MatchupBuilderTests: XCTestCase {
    private let league = SleeperLeague(
        leagueId: "L1", name: "Test League", season: "2026", sport: "nfl", status: "in_season",
        totalRosters: 4, avatar: nil, settings: nil
    )

    private func roster(_ id: Int, owner: String, wins: Int = 0, losses: Int = 0) -> SleeperRoster {
        SleeperRoster(
            rosterId: id, ownerId: owner, leagueId: "L1", players: nil, starters: nil,
            settings: SleeperRoster.Settings(
                wins: wins, losses: losses, ties: nil, fpts: nil, fptsDecimal: nil,
                fptsAgainst: nil, fptsAgainstDecimal: nil
            )
        )
    }

    private func user(_ id: String, name: String, team: String?) -> SleeperLeagueUser {
        SleeperLeagueUser(
            userId: id, displayName: name, avatar: nil,
            metadata: team.map { SleeperLeagueUser.Metadata(teamName: $0) }, isOwner: nil
        )
    }

    private func matchup(_ roster: Int, matchupId: Int?, points: Double?) -> SleeperMatchup {
        SleeperMatchup(
            rosterId: roster, matchupId: matchupId, points: points, customPoints: nil,
            starters: nil, startersPoints: nil, playersPoints: nil
        )
    }

    /// Sunday 4pm ET, week 2 of 2026 (games on).
    private let sundayAfternoon: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 20
        components.hour = 16; components.minute = 0
        return GameWindow.calendar.date(from: components)!
    }()

    /// Wednesday noon ET (between weeks).
    private let wednesdayNoon: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23
        components.hour = 12; components.minute = 0
        return GameWindow.calendar.date(from: components)!
    }()

    func testBuildsHeadToHeadMatchup() throws {
        let snapshot = try MatchupBuilder.build(
            userId: "me",
            league: league,
            week: 2,
            rosters: [roster(1, owner: "me", wins: 1, losses: 0), roster(2, owner: "them", wins: 0, losses: 1)],
            users: [user("me", name: "Neil", team: "Gridiron Gurus"), user("them", name: "Sam", team: nil)],
            matchups: [matchup(1, matchupId: 7, points: 87.42), matchup(2, matchupId: 7, points: 74.1)],
            now: sundayAfternoon
        )

        XCTAssertEqual(snapshot.leagueName, "Test League")
        XCTAssertEqual(snapshot.week, 2)
        XCTAssertEqual(snapshot.me.name, "Gridiron Gurus")
        XCTAssertEqual(snapshot.me.record, "1-0")
        XCTAssertEqual(snapshot.me.points, 87.42, accuracy: 0.001)
        XCTAssertEqual(snapshot.opponent?.name, "Sam", "Falls back to display name when no team name is set")
        XCTAssertEqual(snapshot.opponent?.points ?? 0, 74.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.phase, .live)
        XCTAssertEqual(snapshot.marginText, "+13.32")
        XCTAssertTrue(snapshot.isWinning)
    }

    func testByeWeekHasNoOpponent() throws {
        let snapshot = try MatchupBuilder.build(
            userId: "me",
            league: league,
            week: 9,
            rosters: [roster(1, owner: "me"), roster(2, owner: "them")],
            users: [user("me", name: "Neil", team: nil)],
            matchups: [matchup(1, matchupId: nil, points: 0), matchup(2, matchupId: 3, points: 12)],
            now: sundayAfternoon
        )
        XCTAssertTrue(snapshot.isBye)
        XCTAssertNil(snapshot.opponent)
        XCTAssertEqual(snapshot.phase, .pregame)
    }

    func testMissingRosterThrows() {
        XCTAssertThrowsError(
            try MatchupBuilder.build(
                userId: "nobody", league: league, week: 1,
                rosters: [roster(1, owner: "me")], users: [], matchups: [], now: sundayAfternoon
            )
        ) { error in
            XCTAssertEqual(error as? MatchupServiceError, .noRosterForUser)
        }
    }

    func testFinalPhaseAfterWeekEnds() throws {
        let snapshot = try MatchupBuilder.build(
            userId: "me", league: league, week: 2,
            rosters: [roster(1, owner: "me"), roster(2, owner: "them")],
            users: [],
            matchups: [matchup(1, matchupId: 1, points: 100), matchup(2, matchupId: 1, points: 90)],
            now: wednesdayNoon
        )
        XCTAssertEqual(snapshot.phase, .final)
        XCTAssertEqual(snapshot.me.name, "Team 1", "Unknown owners get a roster-number name")
    }

    func testCustomPointsOverrideComputedPoints() {
        let overridden = SleeperMatchup(
            rosterId: 1, matchupId: 1, points: 50, customPoints: 60.5,
            starters: nil, startersPoints: nil, playersPoints: nil
        )
        XCTAssertEqual(overridden.effectivePoints, 60.5)
    }

    func testActivityContractRoundTrips() throws {
        let snapshot = MatchupSnapshot.preview
        let state = snapshot.activityContentState
        let attributes = snapshot.activityAttributes
        XCTAssertTrue(snapshot.matches(attributes))

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MatchupActivityAttributes.ContentState.self, from: encoded)
        XCTAssertEqual(decoded, state)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["phase"] as? String, "live", "Phase must serialize as a plain string for the push relay")
        XCTAssertNotNil(json["updatedAtUnix"] as? Double)
        XCTAssertEqual(Set(json.keys), ["myPoints", "opponentPoints", "myRecord", "opponentRecord", "phase", "updatedAtUnix"])
    }
}
