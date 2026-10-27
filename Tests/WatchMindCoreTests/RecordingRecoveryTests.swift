import XCTest
@testable import WatchMindCore

final class RecordingRecoveryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testCallNeedsEndPermissionAndForegroundWithUnchangedDeadline() {
        var session = RecordingRecovery(startedAt: now, maximumDuration: 3600)
        session.pause(automatic: false)
        XCTAssertFalse(session.canResume(at: now.addingTimeInterval(30), foreground: true, storageReady: true, systemInterrupted: false, automatic: true))
        session.allowAutomaticResume(true)
        XCTAssertFalse(session.canResume(at: now, foreground: false, storageReady: true, systemInterrupted: false, automatic: true))
        XCTAssertFalse(session.canResume(at: now, foreground: true, storageReady: false, systemInterrupted: false, automatic: true))
        XCTAssertFalse(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: true, automatic: true))
        XCTAssertTrue(session.canResume(at: now.addingTimeInterval(120), foreground: true, storageReady: true, systemInterrupted: false, automatic: true))
        XCTAssertTrue(session.resumed(at: now.addingTimeInterval(120)))
        XCTAssertEqual(session.remaining(at: now.addingTimeInterval(120)), 3480)
        XCTAssertEqual(session.deadline, now.addingTimeInterval(3600))
    }
    func testManualRecoveryDoesNotLoopAutomaticRetries() {
        var session = RecordingRecovery(startedAt: now, maximumDuration: 60)
        session.pause(automatic: true)
        session.allowAutomaticResume(false) // shouldResume absent, route removed, or activation failed
        XCTAssertFalse(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: false, automatic: true))
        XCTAssertTrue(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: false, automatic: false))
        XCTAssertTrue(session.resumed(at: now))
        XCTAssertFalse(session.resumed(at: now))
    }
    func testRouteRemovalManualRequirementSurvivesLaterSystemResumePermission() {
        var session = RecordingRecovery(startedAt: now, maximumDuration: 3600)
        session.pause(automatic: false, manualOnly: true)
        session.allowAutomaticResume(true)
        session.pause(automatic: true) // A later foreground or unlock event must not undo this.
        XCTAssertTrue(session.requiresManualResume)
        XCTAssertFalse(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: false, automatic: true))
        XCTAssertTrue(session.resumed(at: now))
        session.pause(automatic: false); session.allowAutomaticResume(true)
        XCTAssertTrue(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: false, automatic: true))
    }
    func testTimeoutAndStopNeverResumeOrExtendSession() {
        var session = RecordingRecovery(startedAt: now, maximumDuration: 86400)
        session.pause(automatic: true)
        XCTAssertEqual(session.remaining(at: now.addingTimeInterval(86400)), 0)
        XCTAssertFalse(session.resumed(at: now.addingTimeInterval(86400)))
        session.finish(); session.pause(automatic: true); session.allowAutomaticResume(true)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.canResume(at: now, foreground: true, storageReady: true, systemInterrupted: false, automatic: false))
        XCTAssertEqual(RecordingRecovery(startedAt: now, maximumDuration: .infinity).remaining(at: now), 3600)
    }
    func testResumePartAudioAndTranscriptKeepTheInterruptionGap() {
        var owner = Episode(trigger: .init(date: now, bpm: 105, baseline: 70), status: .ready)
        owner.captureStarted = now; owner.audioName = "first.m4a"
        owner.recordingParts = [.init(audioName: "first.m4a", startedAt: now, endedAt: now.addingTimeInterval(30)),
                                .init(audioName: "resumed.m4a", startedAt: now.addingTimeInterval(90), endedAt: now.addingTimeInterval(180))]
        owner.segments = [.init(text: "before call", offset: 10, duration: 5), .init(text: "after call", offset: 100, duration: 5)]
        var marker = Episode(trigger: .init(date: now.addingTimeInterval(105), bpm: 120, baseline: 70), status: .linked)
        marker.linkedRecordingID = owner.id
        XCTAssertEqual(marker.audioLocation(in: [owner]), AudioLocation(audioName: "resumed.m4a", offset: 15))
        XCTAssertEqual(marker.contextSegments(in: [owner]).map(\.text), ["after call"])
        XCTAssertEqual(owner.audioNames, ["first.m4a", "resumed.m4a"])
        marker.trigger.date = now.addingTimeInterval(50)
        XCTAssertNil(marker.audioLocation(in: [owner]), "Never play a later file as if the missing call interval had been recorded")
        marker.trigger.date = now.addingTimeInterval(180)
        XCTAssertNil(marker.audioLocation(in: [owner]))
    }
    func testPartsAndPausedStatusPersistAndLegacyFilesStillResolve() throws {
        var event = Episode(trigger: .init(date: now, bpm: 105, baseline: 70), status: .paused)
        event.captureStarted = now; event.audioName = "old.m4a"
        XCTAssertEqual(event.audioLocation(in: [event]), AudioLocation(audioName: "old.m4a", offset: 0))
        XCTAssertEqual(event.audioNames, ["old.m4a"])
        XCTAssertNil(event.recordingParts)
        event.recordingParts = [.init(audioName: "old.m4a", startedAt: now, endedAt: now.addingTimeInterval(20))]
        let restored = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.recordingParts?.first?.endedAt, now.addingTimeInterval(20))
        XCTAssertEqual(restored.audioNames, ["old.m4a"])
    }
}
