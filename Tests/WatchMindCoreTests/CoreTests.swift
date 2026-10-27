import XCTest
@testable import WatchMindCore

final class CoreTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ bpm: Double, _ seconds: Double) -> HeartSample {
        HeartSample(date: start.addingTimeInterval(seconds), bpm: bpm)
    }
    func testSpikeNeedsBaselineAndUsesPreviousSamples() {
        var detector = HeartDetector()
        for t in 0..<5 { XCTAssertNil(detector.ingest(sample(70, Double(t)), now: start.addingTimeInterval(Double(t)))) }
        let result = detector.ingest(sample(102, 5), now: start.addingTimeInterval(5))
        XCTAssertEqual(result?.baseline, 70)
        XCTAssertEqual(result?.bpm, 102)
    }
    func testRelativeThresholdPreventsSmallRelativeChanges() {
        var d = HeartDetector()
        for t in 0..<5 { _ = d.ingest(sample(120, Double(t)), now: start.addingTimeInterval(Double(t))) }
        XCTAssertNil(d.ingest(sample(125, 5), now: start.addingTimeInterval(5)))
    }
    func testCooldownAndOutOfOrder() {
        var d = HeartDetector()
        for t in 0..<5 { _ = d.ingest(sample(70, Double(t)), now: start.addingTimeInterval(Double(t))) }
        XCTAssertNotNil(d.ingest(sample(105, 5), now: start.addingTimeInterval(5)))
        XCTAssertNil(d.ingest(sample(110, 6), now: start.addingTimeInterval(6)))
        XCTAssertNil(d.ingest(sample(150, 4), now: start.addingTimeInterval(7)))
    }
    func testOldFutureInvalidSamplesDoNotTrigger() {
        var d = HeartDetector()
        XCTAssertNil(d.ingest(sample(100, 0), now: start.addingTimeInterval(60)))
        XCTAssertNil(d.ingest(sample(100, 60), now: start))
        XCTAssertNil(d.ingest(sample(.nan, 0), now: start))
        XCTAssertNil(d.ingest(sample(300, 0), now: start))
    }
    func testGapRequiresNewBaseline() {
        var d = HeartDetector()
        for t in 0..<5 { _ = d.ingest(sample(70, Double(t)), now: start.addingTimeInterval(Double(t))) }
        XCTAssertNil(d.ingest(sample(120, 600), now: start.addingTimeInterval(600)))
    }
    func testDropAlsoTriggers() {
        var d = HeartDetector()
        for t in 0..<5 { _ = d.ingest(sample(110, Double(t)), now: start.addingTimeInterval(Double(t))) }
        XCTAssertNotNil(d.ingest(sample(75, 5), now: start.addingTimeInterval(5)))
    }
    func testSegmentsUseCaptureStartNotTranscriptionCompletion() {
        var e = Episode(trigger: Trigger(date: start, bpm: 110, baseline: 70))
        e.captureStarted = start.addingTimeInterval(2)
        e.segments = [.init(text: "near", offset: 0, duration: 2), .init(text: "late", offset: 25, duration: 2)]
        XCTAssertEqual(Insights.excerpts(e).map(\.text), ["near"])
    }
    func testDailyReportUsesConfirmedFeelingsAndNoInventedCause() throws {
        var e = Episode(trigger: Trigger(date: start, bpm: 110, baseline: 70), status: .ready)
        e.transcript = "今天工作有点累，但是很开心"
        let report = Insights.report(day: start, events: [e])
        XCTAssertTrue(report.text.contains("尚无本人确认"))
        XCTAssertEqual(Set(Insights.cues(in: e.transcript)), Set(["可能涉及疲劳", "可能涉及愉快"]))
        let restored = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(restored.id, e.id)
        XCTAssertEqual(restored.transcript, e.transcript)
    }
    func testDailyFilteringExcludesOtherDays() {
        let e = Episode(trigger: Trigger(date: start, bpm: 100, baseline: 70))
        let tomorrow = Episode(trigger: Trigger(date: start.addingTimeInterval(86400), bpm: 100, baseline: 70))
        XCTAssertEqual(Insights.events(on: start, from: [e, tomorrow]).count, 1)
    }
}
