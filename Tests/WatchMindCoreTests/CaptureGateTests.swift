import XCTest
@testable import WatchMindCore

final class CaptureGateTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ seconds: Double = 0) -> Trigger {
        .init(date: start.addingTimeInterval(seconds), bpm: 110, baseline: 70)
    }
    func testNoSessionMeansNoMicrophone() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.evaluate(event(), now: start, activeSince: nil, foreground: true, busy: false, storageReady: true), .ignore)
        XCTAssertEqual(gate.evaluate(event(-1), now: start, activeSince: start, foreground: true, busy: false, storageReady: true), .ignore)
    }
    func testOnlyFreshForegroundIdleEventRecords() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.evaluate(event(), now: start, activeSince: start, foreground: true, busy: false, storageReady: true), .record)
    }
    func testBackgroundAndBusyNeverRecord() {
        var gate = CaptureGate()
        if case .missed = gate.evaluate(event(), now: start, activeSince: start, foreground: false, busy: false, storageReady: true) {} else { XCTFail("Background must not record") }
        gate.reset()
        if case .missed = gate.evaluate(event(), now: start, activeSince: start, foreground: true, busy: true, storageReady: true) {} else { XCTFail("Concurrent capture must not record") }
    }
    func testDelayedWatchEventIsNotRetrospectivelyRecorded() {
        var gate = CaptureGate()
        if case .missed = gate.evaluate(event(), now: start.addingTimeInterval(16), activeSince: start, foreground: true, busy: false, storageReady: true) {} else { XCTFail("Delayed event must be missed") }
    }
    func testPhoneAndWatchDuplicatesAndOutOfOrderAreIgnored() {
        var gate = CaptureGate()
        _ = gate.evaluate(event(), now: start, activeSince: start, foreground: true, busy: false, storageReady: true)
        XCTAssertEqual(gate.evaluate(event(1), now: start.addingTimeInterval(1), activeSince: start, foreground: true, busy: false, storageReady: true), .ignore)
        XCTAssertEqual(gate.evaluate(event(180), now: start.addingTimeInterval(180), activeSince: start, foreground: true, busy: false, storageReady: true), .record)
        XCTAssertEqual(gate.evaluate(event(10), now: start.addingTimeInterval(181), activeSince: start, foreground: true, busy: false, storageReady: true), .ignore)
    }
    func testNoStorageAndFutureTimestampAreIgnored() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.evaluate(event(), now: start, activeSince: start, foreground: true, busy: false, storageReady: false), .ignore)
        XCTAssertEqual(gate.evaluate(event(60), now: start, activeSince: start, foreground: true, busy: false, storageReady: true), .ignore)
    }
    func testSplitChineseWordsAndChangesHaveTheirOwnOffsets() {
        let segments: [TranscriptSegment] = [
            .init(text: "有点", offset: 0, duration: 0.3),
            .init(text: "紧张。", offset: 0.4, duration: 0.5),
            .init(text: "不过现在很开心。", offset: 4, duration: 2)
        ]
        let moments = Insights.moments(in: segments)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[0].cues, ["可能涉及压力"])
        XCTAssertFalse(moments[0].changedFromPrevious)
        XCTAssertTrue(moments[1].changedFromPrevious)
        XCTAssertEqual(moments[1].offset, 4)
    }
    func testNoLinguisticEvidenceProducesNoEmotionMoments() {
        XCTAssertTrue(Insights.moments(in: [.init(text: "正在走路", offset: 0, duration: 1)]).isEmpty)
    }
}
