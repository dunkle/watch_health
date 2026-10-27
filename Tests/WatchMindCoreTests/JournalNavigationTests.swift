import XCTest
@testable import WatchMindCore

final class JournalNavigationTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func owner(_ start: Date, _ end: Date) -> Episode {
        var event = Episode(trigger: .init(date: start, bpm: 110, baseline: 70), status: .ready)
        event.captureStarted = start; event.captureEnded = end; event.audioName = "first.m4a"
        event.recordingParts = [.init(audioName: "first.m4a", startedAt: start, endedAt: end)]
        return event
    }
    func testMarkerIsIndependentFromHeartTriggerAndKeepsWallClockGap() {
        let start = date("2026-10-27T10:00:00Z")
        var event = owner(start, start.addingTimeInterval(200))
        event.recordingParts = [.init(audioName: "first.m4a", startedAt: start, endedAt: start.addingTimeInterval(30)),
                                .init(audioName: "second.m4a", startedAt: start.addingTimeInterval(90), endedAt: start.addingTimeInterval(200))]
        event.segments = [.init(text: "before", offset: 10, duration: 2), .init(text: "after", offset: 110, duration: 3)]
        let marker = MomentMarker(date: start.addingTimeInterval(112), recordingID: event.id, note: String(repeating: "字", count: 600))
        XCTAssertEqual(marker.note.count, 500)
        XCTAssertEqual(marker.audioLocation(in: [event]), .init(audioName: "second.m4a", offset: 22))
        XCTAssertEqual(marker.context(in: [event]).map(\.text), ["after"])
        XCTAssertNil(MomentMarker(date: start.addingTimeInterval(60), recordingID: event.id).audioLocation(in: [event]))
        XCTAssertNil(marker.owner(in: []))
        XCTAssertNil(MomentMarker(date: start, recordingID: event.id, isDemo: true).owner(in: [event]))
    }
    func testUnfinishedPartDoesNotInventAudioAfterTermination() {
        let start = date("2026-10-27T10:00:00Z")
        var event = owner(start, start.addingTimeInterval(200))
        event.recordingParts?[0].endedAt = nil; event.status = .failed
        let marker = MomentMarker(date: start.addingTimeInterval(100), recordingID: event.id)
        XCTAssertNil(marker.audioLocation(in: [event]))
        event.status = .recording
        XCTAssertNotNil(marker.audioLocation(in: [event]))
        event.status = .paused
        XCTAssertNil(marker.audioLocation(in: [event]))
    }
    func testLegacyAudioAndMarkersRoundTripWithoutNewRequiredFields() throws {
        let start = date("2026-10-27T10:00:00Z")
        var event = owner(start, start.addingTimeInterval(120)); event.recordingParts = nil
        let marker = MomentMarker(date: start.addingTimeInterval(20), recordingID: event.id)
        XCTAssertEqual(marker.audioLocation(in: [event]), .init(audioName: "first.m4a", offset: 20))
        let original = JournalArchive(episodes: [event], markers: [marker])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JournalArchive.self, from: data).markers.first?.id, marker.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); object.removeValue(forKey: "markers")
        XCTAssertTrue(try JSONDecoder().decode(JournalArchive.self, from: JSONSerialization.data(withJSONObject: object)).markers.isEmpty)
    }
    func testCrossMidnightContinuationAndExactHourOwnership() {
        let start = date("2026-10-26T23:50:00Z"), midnight = date("2026-10-27T00:00:00Z")
        let event = owner(start, date("2026-10-27T02:00:00Z"))
        let marker = MomentMarker(date: date("2026-10-27T01:00:00Z"), recordingID: event.id)
        let hours = HourTimeline.buckets(on: midnight, episodes: [event], markers: [marker], calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[0].continuationIDs, [event.id])
        XCTAssertTrue(hours[0].markerIDs.isEmpty)
        XCTAssertEqual(hours[1].markerIDs, [marker.id])
        XCTAssertEqual(hours[1].continuationIDs, [event.id])
        XCTAssertTrue(hours[2].isEmpty, "Recording ending at 02:00 must not appear in the next hour")
    }
    func testMissingHourRemainsEmptyBetweenRecordingParts() {
        let start = date("2026-10-27T08:50:00Z")
        var event = owner(start, date("2026-10-27T11:30:00Z"))
        event.recordingParts = [.init(audioName: "first.m4a", startedAt: start, endedAt: date("2026-10-27T09:00:00Z")),
                                .init(audioName: "second.m4a", startedAt: date("2026-10-27T11:00:00Z"), endedAt: event.captureEnded)]
        let hours = HourTimeline.buckets(on: start, episodes: [event], markers: [], calendar: calendar)
        XCTAssertEqual(hours[8].eventIDs, [event.id])
        XCTAssertTrue(hours[9].isEmpty); XCTAssertTrue(hours[10].isEmpty)
        XCTAssertEqual(hours[11].continuationIDs, [event.id])
    }
    func testDaylightSavingHasUniqueRepeatedHoursAndMissingSpringHour() {
        var c = calendar; c.timeZone = TimeZone(identifier: "America/New_York")!
        let autumn = HourTimeline.buckets(on: date("2026-11-01T12:00:00Z"), episodes: [], markers: [], calendar: c)
        let spring = HourTimeline.buckets(on: date("2026-03-08T12:00:00Z"), episodes: [], markers: [], calendar: c)
        XCTAssertEqual(autumn.count, 25); XCTAssertEqual(spring.count, 23)
        XCTAssertEqual(Set(autumn.map(\.id)).count, 25)
        let repeated = autumn.filter { c.component(.hour, from: $0.start) == 1 }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertNotEqual(c.timeZone.secondsFromGMT(for: repeated[0].start), c.timeZone.secondsFromGMT(for: repeated[1].start))
        XCTAssertFalse(spring.contains { c.component(.hour, from: $0.start) == 2 })
    }
    func testHalfHourDaylightSavingIntervalsCoverTheFullLocalDay() {
        var c = calendar; c.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        for instant in ["2026-04-05T12:00:00Z", "2026-10-04T12:00:00Z"] {
            let day = date(instant), interval = c.dateInterval(of: .day, for: day)!
            let hours = HourTimeline.buckets(on: day, episodes: [], markers: [], calendar: c)
            XCTAssertEqual(hours.first?.start, interval.start)
            XCTAssertEqual(hours.last?.end, interval.end)
            XCTAssertEqual(hours.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, interval.duration)
            XCTAssertTrue(hours.allSatisfy { $0.end > $0.start })
            for pair in zip(hours, hours.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start) }
        }
    }
    func testChangingDisplayZoneDoesNotChangeMarkerOrAudioOffset() {
        let start = date("2026-10-27T22:50:00Z")
        let event = owner(start, start.addingTimeInterval(3600))
        let marker = MomentMarker(date: start.addingTimeInterval(1200), recordingID: event.id)
        var shanghai = calendar; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let before = marker.audioLocation(in: [event])
        let hours = HourTimeline.buckets(on: marker.date, episodes: [event], markers: [marker], calendar: shanghai)
        XCTAssertEqual(hours.flatMap(\.markerIDs), [marker.id])
        XCTAssertEqual(marker.audioLocation(in: [event]), before)
    }
    func testProcessingStagesDoNotInventCompletedTranscriptionOrSync() {
        let start = date("2026-10-27T10:00:00Z")
        var event = Episode(trigger: .init(date: start, bpm: 110, baseline: 70))
        XCTAssertEqual(event.recordingStage, .unavailable); XCTAssertEqual(event.transcriptionStage, .unavailable)
        event.status = .recording; event.captureStarted = start
        XCTAssertEqual(event.recordingStage, .running); XCTAssertEqual(event.transcriptionStage, .pending)
        event.status = .paused
        XCTAssertEqual(event.recordingStage, .paused)
        event.status = .failed
        XCTAssertEqual(event.transcriptionStage, .unknown)
        event.transcriptionAttempted = true; event.captureEnded = start.addingTimeInterval(10)
        XCTAssertEqual(event.transcriptionStage, .failed); XCTAssertEqual(event.recordingStage, .complete)
        event.status = .partial
        XCTAssertEqual(event.transcriptionStage, .partial)
        event.status = .ready
        XCTAssertEqual(event.transcriptionStage, .complete)
    }
}
