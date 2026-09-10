import Foundation

/// Where the fantasy week stands. Stored as a string so the push relay can send it verbatim.
enum MatchupPhase: String, Codable, Hashable, Sendable {
    /// No points yet; games have not started.
    case pregame
    /// Games are being played (or the week is still in its live span).
    case live
    /// The week's games are over.
    case final

    var label: String {
        switch self {
        case .pregame: return "Upcoming"
        case .live: return "Live"
        case .final: return "Final"
        }
    }
}

/// Everything the app and widgets need to draw one fantasy matchup.
/// Persisted in the App Group so the widget extension can render without the network.
struct MatchupSnapshot: Codable, Hashable, Sendable {
    struct Team: Codable, Hashable, Sendable {
        var rosterId: Int
        var name: String
        var ownerName: String?
        var avatarId: String?
        var points: Double
        var record: String?
    }

    var leagueId: String
    var leagueName: String
    var season: String
    var week: Int
    var me: Team
    /// `nil` on a bye week.
    var opponent: Team?
    var phase: MatchupPhase
    var updatedAt: Date

    var isBye: Bool { opponent == nil }

    /// Positive when I'm ahead. Rounded to the cent so a sub-cent floating-point
    /// difference reads as a tie, matching the scores as displayed.
    var margin: Double { ScoreFormat.cents(me.points - (opponent?.points ?? 0)) }

    var isWinning: Bool { margin > 0 }
    var isTied: Bool { margin == 0 }

    /// "+12.4" / "−3.2" / "Tied"
    var marginText: String { ScoreFormat.marginText(margin) }
}

/// Formats fantasy points consistently everywhere ("104.3", not "104.30000000000001").
enum ScoreFormat {
    /// Rounds to two decimals; also folds -0 into 0.
    static func cents(_ value: Double) -> Double {
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded
    }

    /// "+12.4" / "−3.2" / "Tied" for a margin (uses U+2212 so the sign matches the width of "+").
    static func marginText(_ margin: Double) -> String {
        let rounded = cents(margin)
        if rounded == 0 { return "Tied" }
        return (rounded > 0 ? "+" : "−") + points(abs(rounded))
    }

    static func points(_ value: Double) -> String {
        let rounded = cents(value)
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Always one decimal ("104.3"), for tight spaces where width should stay stable.
    static func compactPoints(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
