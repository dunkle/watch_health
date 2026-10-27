import XCTest
@testable import WatchMindCore

final class IntegratedJournalTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func owner(demo: Bool = false) -> Episode {
        var e = Episode(trigger: .init(date: start, bpm: 110, baseline: 70), status: .ready, isDemo: demo)
        e.captureStarted = start; e.captureEnded = start.addingTimeInterval(100)
        e.audioName = "source.m4a"; e.recordingParts = [.init(audioName: "source.m4a", startedAt: start, endedAt: e.captureEnded)]
        e.segments = [.init(text: "I feel", offset: 5, duration: 1), .init(text: "better today", offset: 6, duration: 2)]
        e.transcript = "I feel better today"; return e
    }
    func clip(_ e: Episode) -> EvidenceClip {
        var c = EvidenceClip(recordingID: e.id, date: start.addingTimeInterval(5), offset: 5, duration: 3, text: "I feel better today", isDemo: e.isDemo)
        c.confirmed = true; return c
    }
    func testSourceDeletionRemovesSearchableQuotesAndDisablesMemory() {
        let e = owner(); let c = clip(e)
        var j = JournalCollection(); j.clips = [c]; j.memories = [.init(text: "personal note", clipIDs: [c.id], isDemo: false)]
        XCTAssertTrue(j.memoryHasSources(j.memories[0]))
        j.reconcile(episodes: [])
        XCTAssertTrue(j.clips.isEmpty); XCTAssertFalse(j.memories[0].enabled)
        XCTAssertTrue(JournalSearch.find("better", episodes: [], markers: [], journal: j).isEmpty)
    }
    func testChangedTranscriptInvalidatesConfirmationAndMemory() {
        var e = owner(); let c = clip(e)
        var j = JournalCollection(); j.clips = [c]; j.memories = [.init(text: "my note", clipIDs: [c.id], isDemo: false)]
        j.reconcile(episodes: [e]); XCTAssertTrue(j.clips[0].confirmed)
        e.segments[1].text = "worse today"
        j.reconcile(episodes: [e])
        XCTAssertFalse(j.clips[0].confirmed); XCTAssertFalse(j.memories[0].enabled)
        XCTAssertEqual(j.clips[0].text, "I feel better today", "Keep the saved snapshot for review")
    }
    func testPeopleRemovalOnlyRemovesAssociationsAndKeepsSource() {
        let e = owner(); var c = clip(e); let person = JournalPerson(name: "  Friend  ", isDemo: false)
        c.personIDs = [person.id]; var j = JournalCollection(); j.clips = [c]; j.people = [person]
        XCTAssertEqual(person.name, "Friend")
        XCTAssertFalse(JournalSearch.find("", episodes: [e], markers: [], journal: j, personID: person.id).isEmpty)
        j.people = []; j.reconcile(episodes: [e])
        XCTAssertTrue(j.clips[0].personIDs.isEmpty); XCTAssertEqual(j.clips[0].recordingID, e.id)
    }
    func testSearchFindsSplitChineseAndEnglishButNeverJoinsAcrossAGap() {
        var e = owner(); e.segments = [.init(text: "今天", offset: 0, duration: 1), .init(text: "开心", offset: 1, duration: 1),
                                      .init(text: "Café", offset: 30, duration: 1), .init(text: "meeting", offset: 31, duration: 1)]
        XCTAssertFalse(JournalSearch.find("今天开心", episodes: [e], markers: [], journal: .init()).isEmpty)
        XCTAssertFalse(JournalSearch.find("CAFE meeting", episodes: [e], markers: [], journal: .init()).isEmpty)
        XCTAssertTrue(JournalSearch.find("开心Café", episodes: [e], markers: [], journal: .init()).isEmpty)
        XCTAssertTrue(JournalSearch.find("   ", episodes: [e], markers: [], journal: .init()).isEmpty)
    }
    func testDemoSourceMismatchIsRemoved() {
        let e = owner(); var c = clip(e); c.isDemo = true
        var j = JournalCollection(); j.clips = [c]; j.reconcile(episodes: [e]); XCTAssertTrue(j.clips.isEmpty)
    }
    func testArchiveMigrationAndCollectionMissingFields() throws {
        var archive = JournalArchive(episodes: [owner()]); archive.journal.people = [.init(name: "Friend", isDemo: false)]
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(JournalArchive.self, from: data).journal.people.count, 1)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); dictionary.removeValue(forKey: "journal")
        XCTAssertTrue(try JSONDecoder().decode(JournalArchive.self, from: JSONSerialization.data(withJSONObject: dictionary)).journal.clips.isEmpty)
        let subset = Data("{\"people\":[]}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(JournalCollection.self, from: subset).plans.isEmpty)
    }
    func testCoverageUnionsSharedSourcesAndClipsDayBoundaries() {
        let bounds = DateInterval(start: start, duration: 60)
        XCTAssertEqual(Coverage.seconds([.init(start: start.addingTimeInterval(-20), duration: 50), .init(start: start.addingTimeInterval(10), duration: 40)], within: bounds), 50)
        let e = owner(); var linked = Episode(trigger: .init(date: start.addingTimeInterval(30), bpm: 120, baseline: 70), status: .linked); linked.linkedRecordingID = e.id
        var j = JournalCollection(); var window = ObservationWindow(start: start); window.end = start.addingTimeInterval(200); j.observations = [window]
        j.processing = [.init(recordingID: e.id, audioName: "source.m4a", start: start, end: start.addingTimeInterval(45), outcome: .recognized),
                        .init(recordingID: e.id, audioName: "source.m4a", start: start.addingTimeInterval(45), end: start.addingTimeInterval(90), outcome: .failed)]
        let coverage = Coverage.daily(start, episodes: [e, linked], journal: j, now: start.addingTimeInterval(300), calendar: calendar)
        XCTAssertEqual(coverage.recorded, 100); XCTAssertEqual(coverage.observed, 200)
        XCTAssertEqual(coverage.processed, 45); XCTAssertEqual(coverage.failed, 45)
        XCTAssertEqual(coverage.recordedFraction, 0.5)
        XCTAssertNil(Coverage.daily(start, episodes: [e], journal: .init(), calendar: calendar).observed)
    }
    func testNoCanvasDataDoesNotInventMoodOrActivity() {
        let blocks = HealthReview.canvas(day: start, hearts: [], readings: [], calendar: calendar)
        XCTAssertEqual(blocks.count, 144); XCTAssertTrue(blocks.allSatisfy { $0.signal == .unknown })
        let one = HealthReview.canvas(day: start, hearts: [.init(sample: .init(date: start, bpm: 75))], readings: [], calendar: calendar)
        XCTAssertEqual(one.filter { $0.signal == .heart }.count, 1)
        XCTAssertFalse(one.contains { $0.signal == .activity })
    }
    func testCanvasHandlesDSTAndDoesNotUseInvalidSteps() {
        var c = calendar; c.timeZone = TimeZone(identifier: "America/New_York")!
        let day = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        XCTAssertEqual(HealthReview.canvas(day: day, hearts: [], readings: [], calendar: c).count, 150)
        let invalid = MetricReading(kind: .steps, value: .infinity, date: start, source: "test")
        XCTAssertTrue(HealthReview.canvas(day: start, hearts: [], readings: [invalid], calendar: calendar).allSatisfy { $0.signal == .unknown })
    }
    func testHealthBaselineNeedsDaysAndComparableSources() {
        var readings = (1...7).map { day in MetricReading(kind: .hrv, value: Double(40 + day), date: start.addingTimeInterval(-Double(day) * 86400), source: "Watch") }
        readings.append(.init(kind: .hrv, value: 30, date: start, source: "Watch"))
        XCTAssertNotNil(HealthReview.trend(.hrv, readings: readings, at: start, calendar: calendar)?.baseline)
        readings[0].source = "Other device"
        XCTAssertNil(HealthReview.trend(.hrv, readings: readings, at: start, calendar: calendar)?.baseline)
    }
    func testPurgedAudioKeepsTextEvidenceButCannotPlay() {
        var e = owner(); let c = clip(e); e.audioPurgedAt = start
        XCTAssertNil(e.audioLocation(in: [e])); XCTAssertNil(RecordingTimeline.location(at: c.date, in: e))
        XCTAssertFalse(JournalSearch.find("better", episodes: [e], markers: [], journal: .init()).isEmpty)
    }
    func testAudioSensitivityIsAnEnergyThresholdAndAlwaysFinite() {
        XCTAssertGreaterThan(AudioEnergy.threshold(sensitivity: 1), AudioEnergy.threshold(sensitivity: 5))
        XCTAssertEqual(AudioEnergy.threshold(sensitivity: 999), AudioEnergy.threshold(sensitivity: 5))
        XCTAssertEqual(AudioEnergy.dbfs(meanSquare: 0), -120)
        XCTAssertEqual(AudioEnergy.dbfs(meanSquare: .nan), -120)
        XCTAssertEqual(AudioEnergy.dbfs(meanSquare: 0.01), -20, accuracy: 0.0001)
    }
    func testSpeechFilterKeepsUnknownShortCoverageAndManuallyMarkedRanges() {
        let quiet = AudioQualitySummary(analyzedSeconds: 45, lowEnergySeconds: 40, peakDBFS: -40, sensitivity: 3, speechSeconds: 0)
        XCTAssertTrue(AudioEnergy.shouldSkip(quiet, range: 0..<45, protectedOffsets: []))
        XCTAssertFalse(AudioEnergy.shouldSkip(quiet, range: 0..<45, protectedOffsets: [50]))
        XCTAssertFalse(AudioEnergy.shouldSkip(nil, range: 0..<45, protectedOffsets: []))
        var unknown = quiet; unknown.speechSeconds = nil
        XCTAssertFalse(AudioEnergy.shouldSkip(unknown, range: 0..<45, protectedOffsets: []))
        var short = quiet; short.analyzedSeconds = 20
        XCTAssertFalse(AudioEnergy.shouldSkip(short, range: 0..<45, protectedOffsets: []))
        var speech = quiet; speech.speechSeconds = 0.5
        XCTAssertFalse(AudioEnergy.shouldSkip(speech, range: 0..<45, protectedOffsets: []))
    }
    func testSummaryIncludesManualAndConfirmedEvidenceOnly() {
        let e = owner(); let c = clip(e)
        let marker = MomentMarker(date: c.date, recordingID: e.id, note: "my annotation")
        let report = Insights.report(day: start, events: [], language: .english, recordings: [e], markers: [marker], clips: [c])
        XCTAssertEqual(report.evidenceIDs, [marker.id, c.id]); XCTAssertTrue(report.text.contains("my annotation"))
        var unconfirmed = c; unconfirmed.confirmed = false
        XCTAssertEqual(Insights.report(day: start, events: [], recordings: [e], clips: [unconfirmed]).evidenceIDs, [])
    }
}
