import XCTest
@testable import WatchMindCore

final class HealthContextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ kind: MetricKind, _ value: Double, ago: Double = 0) -> MetricReading {
        .init(kind: kind, value: value, date: now.addingTimeInterval(-ago), source: "fixture")
    }
    func history(_ kind: MetricKind, value: Double) -> [MetricReading] {
        (1...7).map { row(kind, value, ago: Double($0) * 86400) }
    }
    func testMissingAndStaleDataAreNotFilledWithZero() {
        let trigger = Trigger(date: now, bpm: 76, baseline: 70)
        let blank = ContextAlgorithm.assess(trigger, readings: [])
        let stale = ContextAlgorithm.assess(trigger, readings: [row(.hrv, 1, ago: 7 * 3600)])
        XCTAssertEqual(blank.score, stale.score)
        XCTAssertEqual(blank.coverage, 0.6)
        XCTAssertTrue(stale.unavailable.contains(.hrv))
        XCTAssertTrue(stale.contributing.isEmpty)
    }
    func testFreshLowHRVChangesSalienceWhenPersonalBaselineExists() {
        let trigger = Trigger(date: now, bpm: 80, baseline: 70)
        let readings = history(.hrv, value: 60) + [row(.hrv, 20)]
        let result = ContextAlgorithm.assess(trigger, readings: readings)
        XCTAssertTrue(result.contributing.contains(.hrv))
        XCTAssertGreaterThan(result.score, ContextAlgorithm.assess(trigger, readings: []).score)
        XCTAssertGreaterThan(result.coverage, 0.6)
    }
    func testManySamplesFromOneDayDoNotFakeFiveDayBaseline() {
        let readings = (1...100).map { row(.hrv, 60, ago: 86400 + Double($0)) }
        XCTAssertNil(ContextAlgorithm.baseline(.hrv, readings: readings, before: now))
    }
    func testFutureAndInvalidReadingsAreExcluded() {
        let trigger = Trigger(date: now, bpm: 80, baseline: 70)
        let result = ContextAlgorithm.assess(trigger, readings: [row(.oxygen, 150), row(.hrv, .nan), row(.sleepScore, 10, ago: -60)])
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(result.coverage, 0.6)
    }
    func testMovementReducesSalienceButDoesNotAlterHeartTrigger() {
        let trigger = Trigger(date: now, bpm: 90, baseline: 70)
        let rest = ContextAlgorithm.assess(trigger, readings: [])
        let movement = ContextAlgorithm.assess(trigger, readings: [row(.steps, 40), row(.activeEnergy, 3)])
        XCTAssertTrue(movement.activeMovement)
        XCTAssertLessThan(movement.score, rest.score)
    }
    func testAllAuxiliaryMetricsContributeWithFreshnessAndBaselines() {
        var readings: [MetricReading] = []
        for (kind, center, current) in [(MetricKind.oxygen, 98.0, 95.0), (.hrv, 60, 30),
                                        (.environmentalAudio, 45, 70), (.headphoneAudio, 60, 80), (.wristTemperature, 34, 34.4)] {
            readings += history(kind, value: center) + [row(kind, current)]
        }
        readings.append(row(.sleepScore, 50))
        let result = ContextAlgorithm.assess(.init(date: now, bpm: 100, baseline: 70), readings: readings)
        XCTAssertEqual(Set(result.contributing), Set([.oxygen, .hrv, .environmentalAudio, .headphoneAudio, .wristTemperature, .sleepScore]))
        XCTAssertEqual(result.coverage, 1, accuracy: 0.00001)
        XCTAssertTrue((0...100).contains(result.score))
    }
}
