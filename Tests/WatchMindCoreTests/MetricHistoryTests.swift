import XCTest
@testable import WatchMindCore

final class MetricHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    func testStableSourceIDsPreventIdenticalDisplayNamesFromMixing() {
        let own = (1...7).map { MetricReading(kind: .hrv, value: 50, date: now.addingTimeInterval(-Double($0) * 86400), source: "Watch", sourceID: "device-A") }
            + [MetricReading(kind: .hrv, value: 50, date: now, source: "Watch", sourceID: "device-A")]
        let other = (1...7).map { MetricReading(kind: .hrv, value: 300, date: now.addingTimeInterval(-Double($0) * 86400), source: "Watch", sourceID: "device-B") }
        let trigger = Trigger(date: now, bpm: 120, baseline: 100)
        let original = ContextAlgorithm.assess(trigger, readings: own)
        let mixed = ContextAlgorithm.assess(trigger, readings: own + other)
        XCTAssertEqual(mixed.score, original.score, accuracy: 0.0001)
        XCTAssertEqual(mixed.coverage, original.coverage, accuracy: 0.0001)
        XCTAssertNil(ContextAlgorithm.baseline(.hrv, readings: own + other, before: now))
        XCTAssertNil(HealthReview.trend(.hrv, readings: own + other, at: now)?.baseline)
    }
    func testLegacyReadingMigratesWithoutGuessingStableIdentity() throws {
        let old = Data(#"{"id":"old","kind":"hrv","value":50,"date":0,"source":"Watch"}"#.utf8)
        let decoded = try JSONDecoder().decode(MetricReading.self, from: old)
        XCTAssertNil(decoded.sourceID)
        XCTAssertNotEqual(decoded.comparableSourceID, MetricReading(kind: .hrv, value: 50, date: now, source: "Watch", sourceID: "Watch").comparableSourceID)
        let history = (1...7).map { MetricReading(kind: .hrv, value: 100, date: now.addingTimeInterval(-Double($0) * 86400), source: "Watch") }
        let current = MetricReading(kind: .hrv, value: 20, date: now, source: "Watch", sourceID: "stable-watch")
        XCTAssertFalse(ContextAlgorithm.assess(.init(date: now, bpm: 90, baseline: 70), readings: history + [current]).contributing.contains(.hrv))
    }
    func testHistoryStartUsesCalendarAcrossSpringAndFallDST() throws {
        var zone = calendar; zone.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        for (current, expected) in [("2026-03-16T04:00:00Z", "2026-03-02T05:00:00Z"),
                                    ("2026-11-09T05:00:00Z", "2026-10-26T04:00:00Z")] {
            XCTAssertEqual(ContextAlgorithm.historyStart(before: try XCTUnwrap(iso.date(from: current)), calendar: zone), iso.date(from: expected))
        }
    }
    func testDerivedSleepRevisionsHaveStableNightIdentity() throws {
        let night = calendar.startOfDay(for: now).addingTimeInterval(-86400)
        let partial = try XCTUnwrap(MetricHistory.sleepReadings([.init(start: night, end: night.addingTimeInterval(4 * 3600), state: .asleep, source: "watch-A")], calendar: calendar).first)
        let final = try XCTUnwrap(MetricHistory.sleepReadings([.init(start: night, end: night.addingTimeInterval(8 * 3600), state: .asleep, source: "watch-A")], calendar: calendar).first)
        XCTAssertEqual(partial.id, final.id)
        let values = MetricHistory.merge(existing: [partial], snapshot: .init(readings: [final]), at: now, calendar: calendar)
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.value, 100)
    }
    func testCompletedSleepSnapshotReplacesLegacyRevisionsButPreservesOtherMetrics() {
        let old = MetricReading(id: "sleep-old-partial", kind: .sleepScore, value: 50, date: now.addingTimeInterval(-86400), source: "local-duration-only")
        let oxygen = MetricReading(kind: .oxygen, value: 98, date: now.addingTimeInterval(-3600), source: "watch")
        let fresh = MetricReading(id: "sleep-night-final", kind: .sleepScore, value: 100, date: now.addingTimeInterval(-72000), source: "local-duration-only")
        let scope = DateInterval(start: ContextAlgorithm.historyStart(before: now, calendar: calendar), end: now)
        let result = MetricHistory.merge(existing: [old, oxygen], snapshot: .init(readings: [fresh], replacingSleepWindow: scope), at: now, calendar: calendar)
        XCTAssertEqual(Set(result.map(\.id)), Set([oxygen.id, fresh.id]))
        let removed = MetricHistory.merge(existing: [old, oxygen], snapshot: .init(readings: [], replacingSleepWindow: scope), at: now, calendar: calendar)
        XCTAssertEqual(removed.map(\.id), [oxygen.id], "A successful complete query can remove deleted derived evidence")
    }
    func testFailedOrTruncatedQueryCannotEraseCachedSleep() {
        let old = MetricReading(id: "sleep-old-partial", kind: .sleepScore, value: 50, date: now.addingTimeInterval(-86400), source: "local-duration-only")
        let result = MetricHistory.merge(existing: [old], snapshot: .init(readings: []), at: now, calendar: calendar)
        XCTAssertEqual(result.map(\.id), [old.id])
    }
    func testSleepNightUsesLocalNoonAcrossDSTRatherThanTwelveAbsoluteHours() throws {
        var zone = calendar; zone.timeZone = TimeZone(identifier: "America/New_York")!
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-03-08T12:30:00Z")) //08:30EDT
        let end = try XCTUnwrap(iso.date(from: "2026-03-08T16:30:00Z")) //12:30EDT
        let estimate = try XCTUnwrap(SleepScorer.estimates([.init(start: start, end: end, state: .asleep, source: "watch")], calendar: zone).first)
        XCTAssertEqual(estimate.night, iso.date(from: "2026-03-08T05:00:00Z")) //00:00EST
    }
    func testCanvasDoesNotInventKnownHeartFromMalformedSample() {
        let hearts: [HeartPoint] = [.init(sample: .init(date: now, bpm: .nan)), .init(sample: .init(date: now, bpm: 300))]
        XCTAssertTrue(HealthReview.canvas(day: now, hearts: hearts, readings: [], calendar: calendar).allSatisfy { $0.signal == .unknown })
    }
}
