import Foundation

/// Approximates when NFL games are on, in US Eastern time, so the app knows when a
/// matchup Live Activity is "relevant" without a schedule feed.
///
/// A fantasy week is treated as running from Tuesday 05:00 ET to the following
/// Tuesday 05:00 ET (Sleeper advances its week early Tuesday morning).
enum GameWindow {
    struct Window: Hashable, Sendable {
        let start: Date
        let end: Date
        let label: String

        func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    static let eastern = TimeZone(identifier: "America/New_York")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar
    }

    /// 05:00 ET on the Tuesday that starts the fantasy week containing `date`.
    static func weekAnchor(for date: Date) -> Date {
        let cal = calendar
        let weekday = cal.component(.weekday, from: date) // 1 = Sunday ... 3 = Tuesday
        let daysSinceTuesday = (weekday - 3 + 7) % 7
        let tuesday = cal.startOfDay(for: cal.date(byAdding: .day, value: -daysSinceTuesday, to: date) ?? date)
        let anchor = cal.date(bySettingHour: 5, minute: 0, second: 0, of: tuesday) ?? tuesday
        if date < anchor {
            let previous = cal.date(byAdding: .day, value: -7, to: tuesday) ?? tuesday
            return cal.date(bySettingHour: 5, minute: 0, second: 0, of: previous) ?? previous
        }
        return anchor
    }

    /// Game windows for the fantasy week containing `date`, in chronological order.
    /// Saturday games only appear late in the season (weeks 15+).
    static func windows(for date: Date, week: Int) -> [Window] {
        let cal = calendar
        let anchor = weekAnchor(for: date)
        let tuesday = cal.startOfDay(for: anchor)

        func day(_ offset: Int) -> Date {
            cal.date(byAdding: .day, value: offset, to: tuesday) ?? tuesday
        }
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        var windows: [Window] = [
            Window(start: at(day(2), 19, 30), end: at(day(3), 0, 45), label: "Thursday Night"),
        ]
        if week >= 15 {
            windows.append(Window(start: at(day(4), 12, 30), end: at(day(5), 0, 45), label: "Saturday"))
        }
        windows.append(Window(start: at(day(5), 9, 0), end: at(day(6), 0, 45), label: "Sunday"))
        windows.append(Window(start: at(day(6), 19, 30), end: at(day(7), 0, 45), label: "Monday Night"))
        return windows
    }

    /// The window that is on right now, if any.
    static func current(at date: Date = Date(), week: Int) -> Window? {
        windows(for: date, week: week).first { $0.contains(date) }
    }

    /// The next window that starts after `date` (looks ahead one extra week).
    static func next(after date: Date = Date(), week: Int) -> Window? {
        if let upcoming = windows(for: date, week: week).first(where: { $0.start > date }) {
            return upcoming
        }
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: date) ?? date
        return windows(for: nextWeek, week: week + 1).first { $0.start > date }
    }

    /// True from Thursday kickoff through the end of Monday night (Tuesday 02:00 ET),
    /// i.e. while the week's scores can still change.
    static func isLiveSpan(at date: Date = Date()) -> Bool {
        let cal = calendar
        let tuesday = cal.startOfDay(for: weekAnchor(for: date))
        guard let thursday = cal.date(byAdding: .day, value: 2, to: tuesday),
              let nextTuesday = cal.date(byAdding: .day, value: 7, to: tuesday),
              let spanStart = cal.date(bySettingHour: 19, minute: 30, second: 0, of: thursday),
              let spanEnd = cal.date(bySettingHour: 2, minute: 0, second: 0, of: nextTuesday)
        else { return false }
        return date >= spanStart && date < spanEnd
    }

    /// Derives the matchup phase from scores and the time of week.
    static func phase(myPoints: Double, opponentPoints: Double, at date: Date = Date()) -> MatchupPhase {
        let anyPoints = myPoints > 0 || opponentPoints > 0
        if isLiveSpan(at: date) {
            return .live
        }
        return anyPoints ? .final : .pregame
    }
}
