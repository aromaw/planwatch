import XCTest
@testable import PlanWatchCore

final class AlertsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_424_000)
    func window(_ percent: Double?, reset: Double? = nil) -> QuotaWindow {
        QuotaWindow(id: "week", label: "周额度", percent: percent, resetAt: reset)
    }
    func testFirstHighReadingAndJumpOnlySendHighest() {
        XCTAssertEqual(Alerts.evaluate(window: window(97), account: "a", previous: nil, now: now).level, 95)
        XCTAssertEqual(Alerts.evaluate(window: window(100), account: "a", previous: nil, now: now).level, 100)
    }
    func testPersistencePreventsDuplicateButAllowsEscalation() throws {
        let d = Alerts.evaluate(window: window(81), account: "a", previous: nil, now: now)
        let saved = Alerts.delivered(d, now: now)
        let restored = try JSONDecoder().decode(AlertRecord.self, from: JSONEncoder().encode(saved))
        XCTAssertNil(Alerts.evaluate(window: window(90), account: "a", previous: restored, now: now).level)
        XCTAssertEqual(Alerts.evaluate(window: window(96), account: "a", previous: restored, now: now).level, 95)
    }
    func testFailedSendDoesNotConsumeThreshold() {
        let d = Alerts.evaluate(window: window(81), account: "a", previous: nil, now: now)
        XCTAssertEqual(Alerts.evaluate(window: window(81), account: "a", previous: d.record, now: now).level, 80)
    }
    func testResetJitterVersusNewCycleAndAccount() {
        let reset = now.timeIntervalSince1970 + 3600
        let d = Alerts.evaluate(window: window(96, reset: reset), account: "a", previous: nil, now: now)
        let saved = Alerts.delivered(d, now: now)
        XCTAssertNil(Alerts.evaluate(window: window(96, reset: reset + 3), account: "a", previous: saved, now: now).level)
        XCTAssertEqual(Alerts.evaluate(window: window(96, reset: reset + 18000), account: "a", previous: saved, now: now).level, 95)
        XCTAssertEqual(Alerts.evaluate(window: window(96, reset: reset), account: "b", previous: saved, now: now).level, 95)
    }
    func testUnknownAndExpiredWindowsDoNotAlert() {
        XCTAssertNil(Alerts.evaluate(window: window(nil), account: nil, previous: nil, now: now).level)
        XCTAssertNil(Alerts.evaluate(window: window(99, reset: now.timeIntervalSince1970 - 1), account: nil, previous: nil, now: now).level)
    }
    func testRollingRearmNeedsTwoLowReadingsAndCooldown() {
        let saved = Alerts.delivered(Alerts.evaluate(window: window(90), account: nil, previous: nil, now: now), now: now)
        let later = now.addingTimeInterval(700)
        let first = Alerts.evaluate(window: window(50), account: nil, previous: saved, now: later).record
        XCTAssertEqual(first.level, 80)
        let second = Alerts.evaluate(window: window(50), account: nil, previous: first, now: later).record
        XCTAssertEqual(second.level, 0)
        XCTAssertEqual(Alerts.evaluate(window: window(82), account: nil, previous: second, now: later).level, 80)
    }
    func testCorrectedLowUsageDoesNotRearmSameKnownCycle() {
        let reset = now.timeIntervalSince1970 + 10000
        let saved = Alerts.delivered(Alerts.evaluate(window: window(90, reset: reset), account: nil, previous: nil, now: now), now: now)
        let later = now.addingTimeInterval(700)
        let first = Alerts.evaluate(window: window(50, reset: reset), account: nil, previous: saved, now: later).record
        let second = Alerts.evaluate(window: window(50, reset: reset), account: nil, previous: first, now: later).record
        XCTAssertNil(Alerts.evaluate(window: window(90, reset: reset), account: nil, previous: second, now: later).level)
    }
    func testMissingDataAndZeroUsageAreDistinct() throws {
        let json = #"{"provider":"kimi","windows":[{"id":"month","label":"月额度"},{"id":"5h","label":"5 小时","percent":0}],"fetchedAt":1}"#
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.windows[0].remainingPercent)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 100)
    }
}
