import XCTest
@testable import SleeperWidget

/// The Live Activity lifecycle policy, snapshot persistence, and the relay wire contract.
final class PolicyTests: XCTestCase {
    private func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return GameWindow.calendar.date(from: components)!
    }

    private func snapshot(phase: MatchupPhase, week: Int = 2, bye: Bool = false, updatedAt: Date) -> MatchupSnapshot {
        MatchupSnapshot(
            leagueId: "L1", leagueName: "Test", season: "2026", week: week,
            me: .init(rosterId: 1, name: "A", ownerName: nil, avatarId: nil, points: 10, record: "1-0"),
            opponent: bye ? nil : .init(rosterId: 2, name: "B", ownerName: nil, avatarId: nil, points: 5, record: "0-1"),
            phase: phase, updatedAt: updatedAt
        )
    }

    override func tearDown() {
        SharedStore.autoStartSuppressedUntil = nil
        SharedStore.autoStartLiveActivity = true
        SharedStore.relayRegisteredAt = nil
        SharedStore.relayURL = nil
        super.tearDown()
    }

    // MARK: Keep-alive

    func testAutomaticActivityLivesForOneWindow() {
        let sunday = eastern(2026, 9, 20, 16)
        let mondayMorning = eastern(2026, 9, 21, 10)
        let live = snapshot(phase: .live, updatedAt: sunday)
        XCTAssertTrue(MatchupRefresher.shouldKeepActivityAlive(live, manual: false, now: sunday))
        XCTAssertFalse(MatchupRefresher.shouldKeepActivityAlive(live, manual: false, now: mondayMorning), "Between windows an automatic activity ends")
        XCTAssertTrue(MatchupRefresher.shouldKeepActivityAlive(live, manual: true, now: mondayMorning), "A pinned one stays")
        XCTAssertFalse(MatchupRefresher.shouldKeepActivityAlive(snapshot(phase: .final, updatedAt: sunday), manual: true, now: sunday), "Final ends everything")
    }

    // MARK: Auto-start

    func testAutoStartNeedsAWindowAndFreshData() {
        let sunday = eastern(2026, 9, 20, 16)
        XCTAssertTrue(MatchupRefresher.shouldAutoStart(snapshot(phase: .live, updatedAt: sunday), now: sunday))
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(snapshot(phase: .live, updatedAt: sunday), now: eastern(2026, 9, 23, 12)), "No window midweek")
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(snapshot(phase: .live, bye: true, updatedAt: sunday), now: sunday), "Bye week")
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(snapshot(phase: .final, updatedAt: sunday), now: sunday), "Final")
        let stale = snapshot(phase: .live, updatedAt: sunday.addingTimeInterval(-3 * 24 * 3600))
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(stale, now: sunday), "Days-old data must not pin an old matchup")
    }

    func testAutoStartHonoursStopAndTheSettingsToggle() {
        let sunday = eastern(2026, 9, 20, 16)
        let live = snapshot(phase: .live, updatedAt: sunday)
        SharedStore.autoStartSuppressedUntil = sunday.addingTimeInterval(3600)
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(live, now: sunday), "User tapped Stop for this window")
        XCTAssertTrue(MatchupRefresher.shouldAutoStart(live, now: sunday.addingTimeInterval(3601)), "Suppression expires")
        SharedStore.autoStartSuppressedUntil = nil
        SharedStore.autoStartLiveActivity = false
        XCTAssertFalse(MatchupRefresher.shouldAutoStart(live, now: sunday))
    }

    // MARK: Relay-first

    func testRelayFirstOnlyWhileRegisteredRecently() {
        let now = eastern(2026, 9, 20, 16)
        XCTAssertFalse(MatchupRefresher.isRelayHandlingUpdates(now: now), "No relay configured")
        SharedStore.relayURL = URL(string: "https://relay.example.com")
        XCTAssertFalse(MatchupRefresher.isRelayHandlingUpdates(now: now), "Never registered")
        SharedStore.relayRegisteredAt = now.addingTimeInterval(-3600)
        XCTAssertTrue(MatchupRefresher.isRelayHandlingUpdates(now: now))
        SharedStore.relayRegisteredAt = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertFalse(MatchupRefresher.isRelayHandlingUpdates(now: now), "Falls back to background refresh after a day")
    }

    // MARK: Persistence and wire contract

    func testSnapshotRoundTripsThroughTheSharedStore() {
        let original = snapshot(phase: .live, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let previous = SharedStore.snapshot
        defer { SharedStore.snapshot = previous }
        SharedStore.snapshot = original
        XCTAssertEqual(SharedStore.snapshot, original)
        SharedStore.snapshot = nil
        XCTAssertNil(SharedStore.snapshot)
    }

    func testRegistrationWireFormatMatchesTheRelay() throws {
        let registration = RelayClient.Registration(
            installId: "INSTALL-1", userId: "u1", leagueId: "L1",
            pushToStartToken: "aa", activityToken: nil, activityId: nil,
            environment: "development", timeZone: "America/New_York",
            startedManually: true, suppressAutoStartUntil: "2026-09-20T23:45:00Z"
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys ?? []),
            ["installId", "userId", "leagueId", "pushToStartToken", "environment", "timeZone", "startedManually", "suppressAutoStartUntil"],
            "nil optionals are omitted; the relay treats absent as null"
        )
        XCTAssertEqual(object?["startedManually"] as? Bool, true)
        XCTAssertEqual(Data([0x0a, 0xff, 0x00]).hexString, "0aff00")
    }
}
