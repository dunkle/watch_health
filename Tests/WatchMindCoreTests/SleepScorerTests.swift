import XCTest
@testable import WatchMindCore

final class SleepScorerTests: XCTestCase {
    let start = ISO8601DateFormatter().date(from: "2026-10-26T22:00:00Z")!
    var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar }
    func interval(_ from: Double, _ to: Double, _ state: SleepInterval.State, source: String = "watch", priority: Int = 1) -> SleepInterval {
        .init(start: start.addingTimeInterval(from * 3600), end: start.addingTimeInterval(to * 3600), state: state, source: source, priority: priority)
    }
    func testOverlappingStagesAndAwakeAreNotDoubleCounted() throws {
        let result = try XCTUnwrap(SleepScorer.estimates([interval(0, 4, .asleep), interval(2, 6, .asleep), interval(3, 3.5, .awake)], calendar: calendar).first)
        XCTAssertEqual(result.asleepSeconds, 5.5 * 3600)
        XCTAssertNil(result.efficiency)
        XCTAssertEqual(result.score, 5.5 / 8 * 100, accuracy: 0.001)
    }
    func testPreferredSourceDoesNotAddPhoneAndWatchDurations() throws {
        let result = try XCTUnwrap(SleepScorer.estimates([interval(0, 7, .asleep), interval(0, 8, .asleep, source: "phone", priority: 0)], calendar: calendar).first)
        XCTAssertEqual(result.asleepSeconds, 7 * 3600)
    }
    func testInBedEfficiencyAndDurationScoreAreExplicitlyCombined() throws {
        let result = try XCTUnwrap(SleepScorer.estimates([interval(0, 7, .asleep), interval(-0.5, 8, .inBed)], calendar: calendar).first)
        XCTAssertEqual(result.efficiency ?? 0, 7 / 8.5, accuracy: 0.0001)
        XCTAssertEqual(result.score, (0.75 * 7 / 8 + 0.25 * 7 / 8.5) * 100, accuracy: 0.0001)
    }
    func testInBedOnlyAndVeryShortSleepDoNotInventScores() {
        XCTAssertTrue(SleepScorer.estimates([interval(0, 8, .inBed)], calendar: calendar).isEmpty)
        XCTAssertTrue(SleepScorer.estimates([interval(0, 0.1, .asleep)], calendar: calendar).isEmpty)
    }
}
