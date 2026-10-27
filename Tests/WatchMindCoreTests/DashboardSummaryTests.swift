import XCTest
@testable import WatchMindCore

final class DashboardSummaryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func event(_ date: Date, demo: Bool = false, status: CaptureStatus = .ready) -> Episode {
        var result = Episode(trigger: .init(date: date, bpm: 110, baseline: 70), status: status, isDemo: demo)
        result.captureStarted = date; result.audioName = "\(result.id).m4a"; return result
    }
    func testTodayCountsScopeSourcesAndDoNotTreatYesterdayAsToday() {
        let old = event(now.addingTimeInterval(-86400)), today = event(now), demo = event(now, demo: true)
        let manual = MomentMarker(date: now.addingTimeInterval(5), recordingID: old.id)
        let orphan = MomentMarker(date: now, recordingID: UUID())
        let demoMarker = MomentMarker(date: now, recordingID: demo.id, isDemo: true)
        var clip = EvidenceClip(recordingID: today.id, date: now, offset: 0, duration: 1, text: "confirmed", isDemo: false)
        clip.confirmed = true
        var candidate = clip; candidate.id = UUID(); candidate.confirmed = false
        let summary = DashboardSummary.build(day: now, episodes: [old, today, demo], markers: [manual, orphan, demoMarker], clips: [clip, candidate], isDemo: false, calendar: calendar)
        XCTAssertEqual(summary.heartEvents, 1); XCTAssertEqual(summary.manualMarkers, 1); XCTAssertEqual(summary.confirmedHighlights, 1)
        XCTAssertTrue(summary.hasTodayEvidence)
    }
    func testReviewCountUsesOwnersAndExcludesPurgedAndDemo() {
        let partial = event(now.addingTimeInterval(-86400), status: .partial)
        var cleanup = event(now); cleanup.cleanupPending = true
        var purged = event(now, status: .failed); purged.audioPurgedAt = now
        var linked = event(now, status: .failed); linked.linkedRecordingID = partial.id
        let demo = event(now, demo: true, status: .deferred)
        let active = event(now, status: .recording)
        let summary = DashboardSummary.build(day: now, episodes: [partial, cleanup, purged, linked, demo, active], markers: [], clips: [], isDemo: false, calendar: calendar)
        XCTAssertEqual(summary.needsReview, 2)
    }
    func testNoTodayDataLeavesLatestEmptyAndNoInventedScore() {
        let old = event(now.addingTimeInterval(-86400))
        let summary = DashboardSummary.build(day: now, episodes: [old], markers: [], clips: [], isDemo: false, calendar: calendar)
        XCTAssertNil(summary.latest); XCTAssertFalse(summary.hasTodayEvidence)
        XCTAssertEqual(summary.heartEvents + summary.manualMarkers + summary.confirmedHighlights, 0)
    }
    func testLatestMomentIncludesManualEvidenceRatherThanOnlyHeartEvents() {
        let owner = event(now)
        let marker = MomentMarker(date: now.addingTimeInterval(10), recordingID: owner.id, note: "important words")
        let summary = DashboardSummary.build(day: now, episodes: [owner], markers: [marker], clips: [], isDemo: false, calendar: calendar)
        XCTAssertEqual(summary.latest?.id, marker.id); XCTAssertEqual(summary.latest?.source, .manual)
        XCTAssertEqual(summary.latest?.text, marker.note)
    }
    func testDemoSummaryDoesNotLeakRealRecords() {
        let real = event(now), demo = event(now.addingTimeInterval(10), demo: true)
        let marker = MomentMarker(date: now.addingTimeInterval(15), recordingID: real.id)
        let summary = DashboardSummary.build(day: now, episodes: [real, demo], markers: [marker], clips: [], isDemo: true, calendar: calendar)
        XCTAssertEqual(summary.heartEvents, 1); XCTAssertEqual(summary.manualMarkers, 0)
        XCTAssertEqual(summary.latest?.id, demo.id)
    }
}
