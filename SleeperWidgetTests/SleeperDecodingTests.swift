import XCTest
@testable import SleeperWidget

final class SleeperDecodingTests: XCTestCase {
    private let decoder = SleeperAPI.decoder

    func testDecodesUser() throws {
        let json = #"{"user_id":"12345","username":"neil","display_name":"Neil","avatar":"abc123"}"#
        let user = try decoder.decode(SleeperUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.userId, "12345")
        XCTAssertEqual(user.displayName, "Neil")
        XCTAssertEqual(SleeperAPI.avatarThumbnailURL(for: user.avatar)?.absoluteString, "https://sleepercdn.com/avatars/thumbs/abc123")
        XCTAssertNil(SleeperAPI.avatarThumbnailURL(for: nil))
    }

    func testDecodesState() throws {
        let json = #"{"week":2,"display_week":2,"season":"2026","season_type":"regular","league_season":"2026","previous_season":"2025","leg":2,"season_start_date":"2026-09-10"}"#
        let state = try decoder.decode(SleeperState.self, from: Data(json.utf8))
        XCTAssertEqual(state.currentWeek, 2)
        XCTAssertEqual(state.currentLeagueSeason, "2026")
        XCTAssertTrue(state.isRegularOrPostseason)

        let rollover = try decoder.decode(SleeperState.self, from: Data(#"{"week":2,"display_week":3,"season":"2026","season_type":"regular"}"#.utf8))
        XCTAssertEqual(rollover.currentWeek, 3, "display_week wins when it differs from week")
        XCTAssertEqual(rollover.currentLeagueSeason, "2026", "Falls back to season when league_season is absent")

        let offseason = try decoder.decode(SleeperState.self, from: Data(#"{"week":0,"season":"2026","season_type":"off"}"#.utf8))
        XCTAssertEqual(offseason.currentWeek, 1, "Week is clamped to at least 1")
        XCTAssertFalse(offseason.isRegularOrPostseason)
    }

    func testDecodesRosterCoOwners() throws {
        let json = #"[{"roster_id":1,"owner_id":"u1","co_owners":["u9"],"league_id":"L1","settings":{"wins":1,"losses":0}}]"#
        let rosters = try decoder.decode([SleeperRoster].self, from: Data(json.utf8))
        XCTAssertEqual(rosters.first?.coOwners, ["u9"])
        XCTAssertTrue(rosters.first?.isManaged(by: "u9") ?? false)
        XCTAssertTrue(rosters.first?.isManaged(by: "u1") ?? false)
        XCTAssertFalse(rosters.first?.isManaged(by: "u2") ?? true)
    }

    func testDecodesMatchupWithNullsAndIntegers() throws {
        let json = #"""
        [
          {"roster_id":1,"matchup_id":3,"points":104,"custom_points":null,"starters":["4046","0"],"starters_points":[22.5,0],"players_points":{"4046":22.5}},
          {"roster_id":2,"matchup_id":null,"points":0.0,"starters":[],"starters_points":[],"players_points":{}}
        ]
        """#
        let matchups = try decoder.decode([SleeperMatchup].self, from: Data(json.utf8))
        XCTAssertEqual(matchups.count, 2)
        XCTAssertEqual(matchups[0].effectivePoints, 104, "Integer JSON numbers decode as Double")
        XCTAssertNil(matchups[1].matchupId)
        XCTAssertEqual(matchups[1].effectivePoints, 0)
    }

    func testDecodesRosterRecord() throws {
        let json = #"{"roster_id":4,"owner_id":"12345","league_id":"L","players":["1","2"],"starters":["1"],"settings":{"wins":3,"losses":1,"ties":0,"fpts":1234,"fpts_decimal":56,"fpts_against":1100,"fpts_against_decimal":2}}"#
        let roster = try decoder.decode(SleeperRoster.self, from: Data(json.utf8))
        XCTAssertEqual(roster.settings?.recordText, "3-1")
        let tied = SleeperRoster.Settings(wins: 2, losses: 2, ties: 1, fpts: nil, fptsDecimal: nil, fptsAgainst: nil, fptsAgainstDecimal: nil)
        XCTAssertEqual(tied.recordText, "2-2-1")
    }

    func testDecodesLeagueUserTeamName() throws {
        let json = #"[{"user_id":"1","display_name":"Sam","avatar":null,"metadata":{"team_name":"Couch Potatoes"},"is_owner":true},{"user_id":"2","display_name":"Pat","avatar":null,"metadata":null}]"#
        let users = try decoder.decode([SleeperLeagueUser].self, from: Data(json.utf8))
        XCTAssertEqual(users[0].teamName, "Couch Potatoes")
        XCTAssertEqual(users[1].teamName, "Pat")
    }

    func testScoreFormatting() {
        XCTAssertEqual(ScoreFormat.points(104), "104")
        XCTAssertEqual(ScoreFormat.points(104.3), "104.3")
        XCTAssertEqual(ScoreFormat.points(104.30000000000001), "104.3")
        XCTAssertEqual(ScoreFormat.points(87.42), "87.42")
        XCTAssertEqual(ScoreFormat.compactPoints(104), "104.0")
    }
}
