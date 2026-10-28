import XCTest
@testable import WatchMindCore

final class LegacySignalSafetyTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func testLegacyExtremeFiniteMeasurementDecodesButIsNeverConvertedToInt() throws {
        var episode = Episode(trigger: .init(date: date, bpm: 1e300, baseline: 70), status: .ready)
        episode.transcript = "Keep the recorded evidence"
        let data = try JSONEncoder().encode(episode)
        let restored = try JSONDecoder().decode(Episode.self, from: data)
        XCTAssertFalse(restored.trigger.hasValidMeasurements)
        XCTAssertNil(restored.trigger.displayBPM)
        XCTAssertEqual(restored.trigger.displayBaseline, 70)
        XCTAssertFalse(restored.trigger.isLargeChange)
        XCTAssertFalse(restored.isImportant)
        XCTAssertEqual(restored.transcript, episode.transcript, "Display safety must not erase retained speech evidence")
    }
    func testNonfiniteOutOfRangeAndInvalidBaselineStayUnknown() {
        for value in [Double.nan, Double.infinity, -Double.infinity, -1, 0, 29.9, 240.1, 1e300] {
            let heart = Trigger(date: date, bpm: value, baseline: 70)
            XCTAssertNil(heart.displayBPM)
            XCTAssertFalse(heart.hasValidMeasurements)
            XCTAssertFalse(heart.isLargeChange)
            let baseline = Trigger(date: date, bpm: 100, baseline: value)
            XCTAssertNil(baseline.displayBaseline)
            XCTAssertFalse(baseline.hasValidMeasurements)
            XCTAssertFalse(baseline.isLargeChange)
        }
    }
    func testValidBoundariesRemainDisplayableAndPreserveLargeChangeRule() {
        let lower = Trigger(date: date, bpm: 30, baseline: 40)
        let upper = Trigger(date: date, bpm: 240, baseline: 180)
        XCTAssertEqual(lower.displayBPM, 30); XCTAssertEqual(upper.displayBPM, 240)
        XCTAssertTrue(lower.hasValidMeasurements); XCTAssertTrue(upper.hasValidMeasurements)
        XCTAssertFalse(lower.isLargeChange); XCTAssertTrue(upper.isLargeChange)
        XCTAssertTrue(Episode(trigger: upper).isImportant)
    }
    func testInvalidMeasurementsCannotBecomeImportantThroughAnAssessment() {
        var episode = Episode(trigger: .init(date: date, bpm: 100, baseline: 1e300))
        episode.assessment = .init(score: 99, coverage: 1, activeMovement: false, contributing: [], unavailable: [], readings: [])
        XCTAssertFalse(episode.isImportant)
        episode.trigger.baseline = 95
        XCTAssertTrue(episode.isImportant)
        episode.assessment?.score = .infinity
        XCTAssertFalse(episode.isImportant)
    }
    func testPlotOmitsInvalidHeartRatesAndRemovesOnlyInvalidBaselines() {
        let points: [HeartPoint] = [
            .init(sample: .init(date: date, bpm: 70), baseline: 65),
            .init(sample: .init(date: date.addingTimeInterval(10), bpm: 1e300), baseline: 70),
            .init(sample: .init(date: date.addingTimeInterval(20), bpm: .nan), baseline: 70),
            .init(sample: .init(date: date.addingTimeInterval(30), bpm: 80), baseline: 1e300),
            .init(sample: .init(date: date.addingTimeInterval(40), bpm: 90), baseline: .infinity),
            .init(sample: .init(date: date.addingTimeInterval(200), bpm: 75), baseline: 70)
        ]
        let plotted = HeartTimeline.plot(points)
        XCTAssertEqual(plotted.map { $0.point.sample.bpm }, [70, 80, 90, 75])
        XCTAssertEqual(plotted.map { $0.point.baseline }, [65, nil, nil, 70])
        XCTAssertEqual(plotted.map(\.section), [0, 0, 0, 1])
        XCTAssertEqual(points[3].baseline, 1e300, "Plot filtering must not mutate archived source values")
    }
}
