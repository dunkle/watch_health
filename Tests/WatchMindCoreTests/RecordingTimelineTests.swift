import XCTest
@testable import WatchMindCore

final class RecordingTimelineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testHourDefaultBoundsAndChunkCoverage() {
        XCTAssertEqual(RecordingPolicy.duration(minutes: RecordingPolicy.defaultMinutes), 3600)
        XCTAssertEqual(RecordingPolicy.minutes(0), 1)
        XCTAssertEqual(RecordingPolicy.minutes(1000), 180)
        let chunks = RecordingPolicy.chunks(duration: 3600)
        XCTAssertEqual(chunks.count, 80)
        XCTAssertEqual(chunks.first?.lowerBound, 0)
        XCTAssertEqual(chunks.last?.upperBound, 3600)
        for pair in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
        XCTAssertEqual(RecordingPolicy.chunks(duration: 92).last, 90..<92)
        XCTAssertTrue(RecordingPolicy.chunks(duration: .infinity).isEmpty)
    }
    func testGentleTriggerAndIndependentLargeBookmarkDuringCooldown() throws {
        var small = HeartDetector(), large = HeartDetector.largeChanges()
        for i in 0..<5 {
            let sample = HeartSample(date: now.addingTimeInterval(Double(i)), bpm: 70)
            _ = small.ingest(sample, now: sample.date); _ = large.ingest(sample, now: sample.date)
        }
        let gentle = HeartSample(date: now.addingTimeInterval(5), bpm: 76)
        XCTAssertNotNil(small.ingest(gentle, now: gentle.date))
        XCTAssertNil(large.ingest(gentle, now: gentle.date))
        let spike = HeartSample(date: now.addingTimeInterval(6), bpm: 110)
        XCTAssertNil(small.ingest(spike, now: spike.date))
        XCTAssertTrue(try XCTUnwrap(large.ingest(spike, now: spike.date)).isLargeChange)
    }
    func testLinkedMarkerResolvesRecordingAndTimestampedText() {
        var owner = Episode(trigger: .init(date: now, bpm: 80, baseline: 70), status: .ready)
        owner.captureStarted = now; owner.captureEnded = now.addingTimeInterval(3600); owner.audioName = "owner.m4a"
        owner.segments = [.init(text: "beginning", offset: 0, duration: 3),
                          .init(text: "linked context", offset: 120, duration: 5),
                          .init(text: "unmarked private text", offset: 300, duration: 5)]
        var marker = Episode(trigger: .init(date: now.addingTimeInterval(125), bpm: 115, baseline: 70), status: .linked)
        marker.linkedRecordingID = owner.id
        let events = [owner, marker]
        XCTAssertEqual(marker.owner(in: events)?.audioName, "owner.m4a")
        XCTAssertEqual(marker.audioOffset(in: events), 125)
        XCTAssertEqual(Insights.voiceContext(for: marker, events: events), "linked context")
        let report = Insights.report(day: now, events: events, language: .english)
        XCTAssertTrue(report.text.contains("linked context"))
        XCTAssertFalse(report.text.contains("unmarked private text"))
        let nextDayReport = Insights.report(day: now.addingTimeInterval(86400), events: [marker], language: .english, recordings: events)
        XCTAssertTrue(nextDayReport.text.contains("linked context"), "A marker can reference a recording from the previous date")
        XCTAssertNil(marker.owner(in: []))
    }
    func testTracePreservesSpikesAndDisconnectsMissingIntervals() {
        var points = (0..<1000).map { i in HeartPoint(sample: .init(date: now.addingTimeInterval(Double(i)), bpm: i == 550 ? 190 : 70)) }
        let reduced = HeartTimeline.plot(points, limit: 100)
        XCTAssertLessThanOrEqual(reduced.count, 100)
        XCTAssertEqual(reduced.map(\.point.sample.bpm).max(), 190)
        points.append(.init(sample: .init(date: now.addingTimeInterval(1200), bpm: 75)))
        XCTAssertEqual(HeartTimeline.plot(points).last?.section, 1)
    }
    func testLegacyArchiveDecodesWithoutNewSeriesOrMetrics() throws {
        let original = JournalArchive(episodes: [.init(trigger: .init(date: now, bpm: 100, baseline: 70))])
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        dictionary.removeValue(forKey: "heartPoints"); dictionary.removeValue(forKey: "metrics")
        let decoded = try JSONDecoder().decode(JournalArchive.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertEqual(decoded.episodes.count, 1)
        XCTAssertTrue(decoded.heartPoints.isEmpty)
        XCTAssertTrue(decoded.metrics.isEmpty)
    }
}
