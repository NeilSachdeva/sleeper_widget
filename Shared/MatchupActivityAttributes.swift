import ActivityKit
import Foundation

/// Live Activity contract. `ContentState` is what changes during the game and is
/// what the push relay sends in `aps.content-state`; the rest is fixed at start.
///
/// Keep `ContentState` small (the whole push payload must stay under 4 KB) and
/// avoid `Date` inside it so the relay can send plain numbers.
struct MatchupActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var myPoints: Double
        var opponentPoints: Double
        var myRecord: String?
        var opponentRecord: String?
        var phase: MatchupPhase
        /// Unix seconds of the data this state reflects.
        var updatedAtUnix: Double

        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtUnix) }
        var margin: Double { myPoints - opponentPoints }
        var isWinning: Bool { margin > 0 }
        var isTied: Bool { margin == 0 }
        var marginText: String {
            if isTied { return "Tied" }
            return (margin > 0 ? "+" : "−") + ScoreFormat.points(abs(margin))
        }
    }

    var leagueId: String
    var leagueName: String
    var season: String
    var week: Int
    var myTeamName: String
    var myAvatarId: String?
    var opponentTeamName: String
    var opponentAvatarId: String?
}

extension MatchupSnapshot {
    /// Fixed attributes for a Live Activity started from this snapshot.
    var activityAttributes: MatchupActivityAttributes {
        MatchupActivityAttributes(
            leagueId: leagueId,
            leagueName: leagueName,
            season: season,
            week: week,
            myTeamName: me.name,
            myAvatarId: me.avatarId,
            opponentTeamName: opponent?.name ?? "Bye week",
            opponentAvatarId: opponent?.avatarId
        )
    }

    /// Dynamic state for a Live Activity.
    var activityContentState: MatchupActivityAttributes.ContentState {
        MatchupActivityAttributes.ContentState(
            myPoints: me.points,
            opponentPoints: opponent?.points ?? 0,
            myRecord: me.record,
            opponentRecord: opponent?.record,
            phase: phase,
            updatedAtUnix: updatedAt.timeIntervalSince1970
        )
    }

    /// True when this snapshot describes the same matchup an activity was started for.
    func matches(_ attributes: MatchupActivityAttributes) -> Bool {
        attributes.leagueId == leagueId && attributes.week == week && attributes.season == season
    }
}

// MARK: - Sample data for previews and tests

extension MatchupActivityAttributes {
    static let preview = MatchupActivityAttributes(
        leagueId: "123456789012345678",
        leagueName: "Sunday Scaries",
        season: "2026",
        week: 2,
        myTeamName: "Gridiron Gurus",
        myAvatarId: nil,
        opponentTeamName: "Couch Potatoes",
        opponentAvatarId: nil
    )
}

extension MatchupActivityAttributes.ContentState {
    static let previewLive = MatchupActivityAttributes.ContentState(
        myPoints: 87.42,
        opponentPoints: 74.1,
        myRecord: "1-0",
        opponentRecord: "0-1",
        phase: .live,
        updatedAtUnix: Date().timeIntervalSince1970 - 120
    )

    static let previewTrailing = MatchupActivityAttributes.ContentState(
        myPoints: 61.3,
        opponentPoints: 98.76,
        myRecord: "1-0",
        opponentRecord: "0-1",
        phase: .live,
        updatedAtUnix: Date().timeIntervalSince1970 - 30
    )

    static let previewFinal = MatchupActivityAttributes.ContentState(
        myPoints: 132.5,
        opponentPoints: 118.02,
        myRecord: "2-0",
        opponentRecord: "0-2",
        phase: .final,
        updatedAtUnix: Date().timeIntervalSince1970 - 3600
    )
}

extension MatchupSnapshot {
    static let preview = MatchupSnapshot(
        leagueId: MatchupActivityAttributes.preview.leagueId,
        leagueName: MatchupActivityAttributes.preview.leagueName,
        season: "2026",
        week: 2,
        me: Team(rosterId: 1, name: "Gridiron Gurus", ownerName: "neil", avatarId: nil, points: 87.42, record: "1-0"),
        opponent: Team(rosterId: 4, name: "Couch Potatoes", ownerName: "sam", avatarId: nil, points: 74.1, record: "0-1"),
        phase: .live,
        updatedAt: Date().addingTimeInterval(-120)
    )

    static let previewBye = MatchupSnapshot(
        leagueId: MatchupActivityAttributes.preview.leagueId,
        leagueName: MatchupActivityAttributes.preview.leagueName,
        season: "2026",
        week: 9,
        me: Team(rosterId: 1, name: "Gridiron Gurus", ownerName: "neil", avatarId: nil, points: 0, record: "5-3"),
        opponent: nil,
        phase: .pregame,
        updatedAt: Date()
    )
}
