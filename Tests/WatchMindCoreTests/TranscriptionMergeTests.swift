import XCTest
@testable import WatchMindCore

final class TranscriptionMergeTests: XCTestCase {
    func testPartialRetryRetainsOldSuccessfulWordsInFailedRange() {
        let old = FileTranscript(audioName: "a", text: "old beginning", segments: [.init(text: "old beginning", offset: 3, duration: 2)])
        let merged = TranscriptionMerge.merge(previous: old, audioName: "a", text: "new ending",
            segments: [.init(text: "new ending", offset: 50, duration: 2)],
            spans: [.init(0..<45, outcome: .failed), .init(45..<90, outcome: .recognized)], completeRange: 0..<90)
        XCTAssertEqual(merged.segments.map(\.text), ["old beginning", "new ending"])
        XCTAssertTrue(merged.text.contains("old beginning"))
    }
    func testSuccessfulEmptyChunkRemovesOldWordsOnlyInThatChunk() {
        let old = FileTranscript(audioName: "a", text: "first second", segments: [.init(text: "first", offset: 2, duration: 1), .init(text: "second", offset: 52, duration: 1)])
        let merged = TranscriptionMerge.merge(previous: old, audioName: "a", text: "", segments: [],
            spans: [.init(0..<45, outcome: .empty), .init(45..<90, outcome: .failed)])
        XCTAssertEqual(merged.segments.map(\.text), ["second"])
    }
    func testCheckpointLeavesUnattemptedRangesAndAppliesFileOffsetOnce() {
        let old = FileTranscript(audioName: "b", text: "old late", segments: [.init(text: "old", offset: 103, duration: 1), .init(text: "late", offset: 160, duration: 1)])
        let merged = TranscriptionMerge.merge(previous: old, audioName: "b", text: "replacement",
            segments: [.init(text: "replacement", offset: 3, duration: 1)], spans: [.init(0..<45, outcome: .recognized)], offset: 100)
        XCTAssertEqual(merged.segments.map(\.offset), [103, 160])
        XCTAssertEqual(merged.segments.map(\.text), ["replacement", "late"])
    }
    func testResumeRequiresSuccessfulUnionWithoutGapsAndNeverUsesSkippedOrFailed() {
        XCTAssertTrue(TranscriptionMerge.isCompleted(0..<45, spans: [.init(0..<20, outcome: .recognized), .init(20..<45, outcome: .empty)]))
        XCTAssertFalse(TranscriptionMerge.isCompleted(0..<45, spans: [.init(0..<20, outcome: .recognized), .init(21..<45, outcome: .recognized)]))
        XCTAssertFalse(TranscriptionMerge.isCompleted(0..<45, spans: [.init(0..<45, outcome: .failed)]))
        XCTAssertFalse(TranscriptionMerge.isCompleted(0..<45, spans: [.init(0..<45, outcome: .skipped)]))
    }
    func testLegacyUnalignedTextOnlyReplacedAfterCompleteSuccess() {
        let old = FileTranscript(audioName: "a", text: "legacy full transcript", segments: [])
        let partial = TranscriptionMerge.merge(previous: old, audioName: "a", text: "new beginning", segments: [.init(text: "new", offset: 1, duration: 1)],
            spans: [.init(0..<45, outcome: .recognized)], completeRange: 0..<90)
        XCTAssertEqual(partial.text, old.text); XCTAssertTrue(partial.segments.isEmpty)
        let complete = TranscriptionMerge.merge(previous: old, audioName: "a", text: "New, complete transcript!", segments: [.init(text: "New", offset: 1, duration: 1)],
            spans: [.init(0..<90, outcome: .recognized)], completeRange: 0..<90)
        XCTAssertEqual(complete.text, "New, complete transcript!")
    }
    func testSkippedOrInvalidSpanDoesNotEraseEarlierEvidence() {
        let old = FileTranscript(audioName: "a", text: "kept", segments: [.init(text: "kept", offset: 2, duration: 1)])
        for span in [TranscriptionChunkSpan(0..<45, outcome: .skipped), .init(0..<Double.infinity, outcome: .recognized)] {
            let merged = TranscriptionMerge.merge(previous: old, audioName: "a", text: "", segments: [], spans: [span])
            XCTAssertEqual(merged.text, "kept")
            XCTAssertEqual(merged.segments, old.segments)
        }
    }
    func testIdempotentCheckpointDoesNotDuplicateTextOrInventGapWords() {
        let old = FileTranscript(audioName: "a", text: "old", segments: [.init(text: "old", offset: 2, duration: 1)])
        let spans: [TranscriptionChunkSpan] = [.init(45..<90, outcome: .recognized)]
        let next = [TranscriptSegment(text: "later", offset: 50, duration: 1)]
        let first = TranscriptionMerge.merge(previous: old, audioName: "a", text: "later", segments: next, spans: spans)
        let second = TranscriptionMerge.merge(previous: first, audioName: "a", text: "later", segments: next, spans: spans)
        XCTAssertEqual(second.segments, first.segments)
        XCTAssertEqual(second.segments.count, 2)
        XCTAssertEqual(second.segments.map(\.offset), [2, 50])
    }
}
