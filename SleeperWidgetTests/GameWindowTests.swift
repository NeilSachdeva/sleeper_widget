import XCTest
@testable import SleeperWidget

final class GameWindowTests: XCTestCase {
    private func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return GameWindow.calendar.date(from: components)!
    }

    func testWeekAnchorIsPrecedingTuesdayMorning() {
        // Sunday Sept 20, 2026 → anchor Tuesday Sept 15, 05:00 ET
        let anchor = GameWindow.weekAnchor(for: eastern(2026, 9, 20, 16))
        XCTAssertEqual(anchor, eastern(2026, 9, 15, 5))

        // Tuesday 03:00 belongs to the previous week
        XCTAssertEqual(GameWindow.weekAnchor(for: eastern(2026, 9, 22, 3)), eastern(2026, 9, 15, 5))
        // Tuesday 06:00 starts the new week
        XCTAssertEqual(GameWindow.weekAnchor(for: eastern(2026, 9, 22, 6)), eastern(2026, 9, 22, 5))
    }

    func testSundayAfternoonIsInSundayWindow() {
        let window = GameWindow.current(at: eastern(2026, 9, 20, 16), week: 2)
        XCTAssertEqual(window?.label, "Sunday")
    }

    func testThursdayNightAndMondayNight() {
        XCTAssertEqual(GameWindow.current(at: eastern(2026, 9, 17, 21), week: 2)?.label, "Thursday Night")
        XCTAssertEqual(GameWindow.current(at: eastern(2026, 9, 21, 22), week: 2)?.label, "Monday Night")
        // Just past midnight after Monday night still counts.
        XCTAssertEqual(GameWindow.current(at: eastern(2026, 9, 22, 0, 30), week: 2)?.label, "Monday Night")
    }

    func testThanksgivingAfternoonIsLive() {
        // Thanksgiving 2026 is Thu Nov 26 (12:30 / 16:30 / 20:20 ET kickoffs).
        XCTAssertEqual(GameWindow.holidayLabel(for: eastern(2026, 11, 26, 12)), "Thanksgiving")
        XCTAssertNil(GameWindow.holidayLabel(for: eastern(2026, 11, 19, 12)), "The Thursday before is ordinary")
        XCTAssertEqual(GameWindow.phase(myPoints: 8.4, opponentPoints: 0, at: eastern(2026, 11, 26, 14)), .live)
        XCTAssertEqual(GameWindow.current(at: eastern(2026, 11, 26, 14), week: 12)?.label, "Thanksgiving")
        XCTAssertTrue(GameWindow.isLiveSpan(at: eastern(2026, 11, 26, 12, 30)))
        XCTAssertFalse(GameWindow.isLiveSpan(at: eastern(2026, 11, 26, 11)))
        XCTAssertNil(GameWindow.current(at: eastern(2026, 11, 19, 14), week: 11), "An ordinary Thursday afternoon stays off")
        XCTAssertEqual(GameWindow.windows(for: eastern(2026, 11, 26, 14), week: 12).map(\.label), ["Thanksgiving", "Sunday", "Monday Night"])
    }

    func testChristmasMidweekIsLive() {
        // Christmas 2030 falls on a Wednesday.
        XCTAssertEqual(GameWindow.phase(myPoints: 10, opponentPoints: 0, at: eastern(2030, 12, 25, 14)), .live)
        XCTAssertEqual(GameWindow.current(at: eastern(2030, 12, 25, 14), week: 17)?.label, "Christmas")
        XCTAssertEqual(GameWindow.current(at: eastern(2030, 12, 26, 21), week: 17)?.label, "Thursday Night")
        // Christmas 2025 falls on a Thursday and replaces the night window.
        XCTAssertEqual(GameWindow.current(at: eastern(2025, 12, 25, 14), week: 17)?.label, "Christmas")
        XCTAssertEqual(GameWindow.windows(for: eastern(2025, 12, 25, 14), week: 17).map(\.label), ["Christmas", "Saturday", "Sunday", "Monday Night"])
        // Christmas on a Friday (2026) is an ordinary week.
        XCTAssertNil(GameWindow.holidayLabel(for: eastern(2026, 12, 25, 14)))
    }

    func testNegativeOnlyScoringIsFinalAfterTheWeek() {
        XCTAssertEqual(GameWindow.phase(myPoints: -1.2, opponentPoints: 0, at: eastern(2026, 9, 23, 12)), .final)
        XCTAssertEqual(GameWindow.phase(myPoints: 0, opponentPoints: 0, at: eastern(2026, 9, 23, 12)), .pregame)
    }

    func testNoWindowMidweekOrSundayMorning() {
        XCTAssertNil(GameWindow.current(at: eastern(2026, 9, 23, 12), week: 2))
        XCTAssertNil(GameWindow.current(at: eastern(2026, 9, 20, 7), week: 2))
        XCTAssertNil(GameWindow.current(at: eastern(2026, 9, 19, 15), week: 2), "No Saturday games early in the season")
    }

    func testSaturdayWindowLateSeason() {
        XCTAssertEqual(GameWindow.current(at: eastern(2026, 12, 19, 15), week: 15)?.label, "Saturday")
    }

    func testNextWindowFromMidweekIsThursday() {
        let next = GameWindow.next(after: eastern(2026, 9, 16, 12), week: 2)
        XCTAssertEqual(next?.label, "Thursday Night")
        XCTAssertEqual(next?.start, eastern(2026, 9, 17, 19, 30))
    }

    func testNextWindowRollsIntoFollowingWeek() {
        let next = GameWindow.next(after: eastern(2026, 9, 22, 3), week: 2)
        XCTAssertEqual(next?.label, "Thursday Night")
        XCTAssertEqual(next?.start, eastern(2026, 9, 24, 19, 30))
    }

    func testLiveSpan() {
        XCTAssertTrue(GameWindow.isLiveSpan(at: eastern(2026, 9, 18, 12)), "Friday is inside the week's live span")
        XCTAssertFalse(GameWindow.isLiveSpan(at: eastern(2026, 9, 16, 12)), "Wednesday is between weeks")
        XCTAssertFalse(GameWindow.isLiveSpan(at: eastern(2026, 9, 22, 3)), "Tuesday 3am is after the span ends")
    }

    func testPhaseDerivation() {
        XCTAssertEqual(GameWindow.phase(myPoints: 0, opponentPoints: 0, at: eastern(2026, 9, 16, 12)), .pregame)
        XCTAssertEqual(GameWindow.phase(myPoints: 0, opponentPoints: 0, at: eastern(2026, 9, 20, 13)), .live)
        XCTAssertEqual(GameWindow.phase(myPoints: 90, opponentPoints: 80, at: eastern(2026, 9, 22, 12)), .final)
    }

    func testDaylightSavingTransitionKeepsWallClockTimes() {
        // DST ends Sunday Nov 1, 2026 in the US; Sunday window should still start at 09:00 local.
        let window = GameWindow.current(at: eastern(2026, 11, 1, 13), week: 8)
        XCTAssertEqual(window?.label, "Sunday")
        XCTAssertEqual(window?.start, eastern(2026, 11, 1, 9))
    }
}
