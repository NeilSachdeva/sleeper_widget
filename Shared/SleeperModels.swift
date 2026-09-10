import Foundation

// MARK: - Sleeper public API models
//
// Sleeper's read-only API (https://docs.sleeper.com) returns snake_case JSON.
// Keys are spelled out explicitly below so the mapping is obvious and so the
// push relay in `server/` can mirror it exactly.

struct SleeperUser: Codable, Hashable, Identifiable {
    let userId: String
    let username: String?
    let displayName: String?
    let avatar: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatar
    }
}

struct SleeperLeague: Codable, Hashable, Identifiable {
    struct Settings: Codable, Hashable {
        let playoffWeekStart: Int?
        let leg: Int?

        enum CodingKeys: String, CodingKey {
            case playoffWeekStart = "playoff_week_start"
            case leg
        }
    }

    let leagueId: String
    let name: String
    let season: String
    let sport: String?
    let status: String?
    let totalRosters: Int?
    let avatar: String?
    let settings: Settings?

    var id: String { leagueId }

    enum CodingKeys: String, CodingKey {
        case leagueId = "league_id"
        case name
        case season
        case sport
        case status
        case totalRosters = "total_rosters"
        case avatar
        case settings
    }
}

struct SleeperRoster: Codable, Hashable {
    struct Settings: Codable, Hashable {
        let wins: Int?
        let losses: Int?
        let ties: Int?
        /// Whole-number part of season points; combine with `fptsDecimal`.
        let fpts: Double?
        let fptsDecimal: Double?
        let fptsAgainst: Double?
        let fptsAgainstDecimal: Double?

        enum CodingKeys: String, CodingKey {
            case wins, losses, ties, fpts
            case fptsDecimal = "fpts_decimal"
            case fptsAgainst = "fpts_against"
            case fptsAgainstDecimal = "fpts_against_decimal"
        }

        /// "3-1" or "3-1-1" when there are ties.
        var recordText: String {
            let w = wins ?? 0, l = losses ?? 0, t = ties ?? 0
            return t > 0 ? "\(w)-\(l)-\(t)" : "\(w)-\(l)"
        }
    }

    // Only what the matchup needs is decoded. Sleeper also sends `players`,
    // `starters`, and `reserve`, but decoding them buys nothing here.
    let rosterId: Int
    let ownerId: String?
    let leagueId: String?
    let settings: Settings?

    enum CodingKeys: String, CodingKey {
        case rosterId = "roster_id"
        case ownerId = "owner_id"
        case leagueId = "league_id"
        case settings
    }
}

struct SleeperLeagueUser: Codable, Hashable, Identifiable {
    struct Metadata: Codable, Hashable {
        let teamName: String?

        enum CodingKeys: String, CodingKey {
            case teamName = "team_name"
        }
    }

    let userId: String
    let displayName: String?
    let avatar: String?
    let metadata: Metadata?
    let isOwner: Bool?

    var id: String { userId }

    /// Team name if the manager set one, otherwise their display name.
    var teamName: String {
        if let name = metadata?.teamName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return displayName ?? "Team"
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatar
        case metadata
        case isOwner = "is_owner"
    }
}

struct SleeperMatchup: Codable, Hashable {
    // `starters`, `starters_points`, and `players_points` are the bulk of this
    // response and are intentionally not decoded.
    let rosterId: Int
    /// Two rosters share a `matchupId` in a given week. `nil` on a bye week.
    let matchupId: Int?
    let points: Double?
    let customPoints: Double?

    enum CodingKeys: String, CodingKey {
        case rosterId = "roster_id"
        case matchupId = "matchup_id"
        case points
        case customPoints = "custom_points"
    }

    /// Commissioner overrides win over computed points.
    var effectivePoints: Double { customPoints ?? points ?? 0 }
}

struct SleeperState: Codable, Hashable {
    let week: Int
    let displayWeek: Int?
    let season: String
    let seasonType: String
    let leagueSeason: String?
    let previousSeason: String?
    let leg: Int?
    let seasonStartDate: String?

    enum CodingKeys: String, CodingKey {
        case week
        case displayWeek = "display_week"
        case season
        case seasonType = "season_type"
        case leagueSeason = "league_season"
        case previousSeason = "previous_season"
        case leg
        case seasonStartDate = "season_start_date"
    }

    /// Week whose matchups Sleeper itself shows; `display_week` can run ahead of
    /// `week` around the Tuesday rollover, so prefer it when present.
    var currentWeek: Int { max(1, displayWeek ?? week) }

    /// Season that leagues are keyed on (differs from `season` during the offseason).
    var currentLeagueSeason: String { leagueSeason ?? season }

    var isRegularOrPostseason: Bool { seasonType == "regular" || seasonType == "post" }
}
