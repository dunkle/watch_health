import XCTest
@testable import WatchMindCore

final class AIReviewRepairTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func recording(words: [String], duration: Double) -> Episode {
        var owner = Episode(trigger: .init(date: start, bpm: 90, baseline: 70), status: .ready)
        owner.captureStarted = start; owner.captureEnded = start.addingTimeInterval(duration)
        owner.segments = words.enumerated().map { .init(text: $0.element, offset: Double($0.offset) / 2, duration: 0.3) }
        return owner
    }
    private func evidence(_ owner: Episode, duration: Double, dense: Bool = false) throws -> AIReviewEvidence {
        let hearts: [HeartPoint] = dense ? (0..<Int(duration)).map { .init(sample: .init(date: start.addingTimeInterval(Double($0)), bpm: Double(80 + $0 % 5)), baseline: 70) } : []
        return try .build(selection: .init(recordingID: owner.id, start: start, end: start.addingTimeInterval(duration)),
                          episodes: [owner], heartPoints: hearts, metrics: [], isDemo: false)
    }
    func testSubsecondWireTimesRoundTripWithMillisecondPrecision() throws {
        let owner = recording(words: ["hello"], duration: 1)
        let selection = AIReviewSelection(recordingID: owner.id, start: start.addingTimeInterval(0.1), end: start.addingTimeInterval(0.2), includeHeart: false)
        let evidence = try AIReviewEvidence.build(selection: selection, episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try evidence.preview.utf8)) as? [String: Any])
        let selected = try XCTUnwrap(object["selection"] as? [String: Any])
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let a = try XCTUnwrap(formatter.date(from: try XCTUnwrap(selected["start"] as? String)))
        let b = try XCTUnwrap(formatter.date(from: try XCTUnwrap(selected["end"] as? String)))
        XCTAssertEqual(b.timeIntervalSince(a), 0.1, accuracy: 0.001)
    }
    func testNormalFiveAndTenMinuteEnglishAndChineseRetainAllWordsAndDenseHeartSamples() throws {
        for minutes in [5, 10] {
            for chinese in [false, true] {
                let words = (0..<(minutes * 120)).map { chinese ? "讨论\($0)" : "topic\($0)" }
                let owner = recording(words: words, duration: Double(minutes * 60))
                let value = try evidence(owner, duration: Double(minutes * 60), dense: true)
                XCTAssertLessThanOrEqual(try value.preview.count, AIReviewEvidence.maximumPayloadCharacters)
                XCTAssertEqual(value.heartPoints.count, minutes * 60)
                let text = value.transcript.map(\.text).joined(separator: " ")
                for word in words { XCTAssertTrue(text.contains(word)) }
                XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).count, words.count)
                XCTAssertLessThan(value.transcript.count, words.count / 4)
            }
        }
    }
    func testLocalBudgetPartitionsRetainAllEvidenceAndRespectPayloadBounds() throws {
        let words = (0..<1200).map { "topic\($0)" }
        let value = try evidence(recording(words: words, duration: 600), duration: 600, dense: true)
        let batches = try value.localBatches()
        XCTAssertGreaterThan(batches.count, 1)
        for batch in batches { XCTAssertLessThanOrEqual(try batch.preview.count, 3400) }
        let retained = Set(batches.flatMap { $0.transcript.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) } })
        XCTAssertEqual(retained, Set(words))
        XCTAssertEqual(Set(batches.flatMap(\.heartPoints).map { $0.sample.date }), Set(value.heartPoints.map { $0.sample.date }))
        XCTAssertEqual(batches.flatMap(\.heartPoints).count, value.heartPoints.count)
    }
    func testWordGroupingNeverBridgesAnActualRecordingInterruption() throws {
        var owner = recording(words: [], duration: 21)
        owner.recordingParts = [.init(audioName: "one.m4a", startedAt: start, endedAt: start.addingTimeInterval(10)),
                                .init(audioName: "two.m4a", startedAt: start.addingTimeInterval(10.2), endedAt: start.addingTimeInterval(21))]
        owner.segments = [.init(text: "first", offset: 9.6, duration: 0.3), .init(text: "second", offset: 10.25, duration: 0.3)]
        let value = try evidence(owner, duration: 21)
        XCTAssertEqual(value.transcript.map(\.text), ["first", "second"])
        XCTAssertEqual(value.audioWindows.count, 2)
    }
    func testWireHealthMetadataDefinesUnitsAggregationAndLocalEstimates() throws {
        let rows: [MetricReading] = [.init(kind: .steps, value: 30, date: start, source: "Watch", sourceID: "LOCAL_ONLY_DEVICE_HASH"),
                                     .init(kind: .activeEnergy, value: 3, date: start, source: "Watch"),
                                     .init(kind: .sleepScore, value: 80, date: start, source: "local-duration-only")]
        let value = try AIReviewEvidence.build(selection: .init(start: start, end: start.addingTimeInterval(60), includeTranscript: false, includeHeart: false, metricKinds: [.steps, .activeEnergy, .sleepScore]), episodes: [], heartPoints: [], metrics: rows, isDemo: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try value.preview.utf8)) as? [String: Any])
        let semantics = try XCTUnwrap(object["metricSemantics"] as? [String: [Any]])
        XCTAssertEqual(semantics["steps"]?[0] as? String, "steps")
        XCTAssertEqual(semantics["steps"]?[1] as? Int, 300)
        XCTAssertEqual(semantics["sleepScore"]?[2] as? Bool, true)
        XCTAssertTrue(try value.preview.contains("not an Apple or medical score"))
        XCTAssertFalse(try value.preview.contains("LOCAL_ONLY_DEVICE_HASH"))
        XCTAssertFalse(try value.preview.contains(rows[0].id))
    }
    func testDatePickerAndSliderShareExactBoundsAndMinimumDuration() throws {
        var range = try XCTUnwrap(AIReviewRange(began: start, ended: start.addingTimeInterval(100), start: start.addingTimeInterval(1000), end: start.addingTimeInterval(-20)))
        for offset in [-100.0, 0, 0.1, 99.9, 100, 1000] {
            range.setStart(start.addingTimeInterval(offset))
            XCTAssertTrue(range.startOffsets.contains(range.startOffset))
            XCTAssertTrue(range.endOffsets.contains(range.endOffset))
            XCTAssertGreaterThanOrEqual(range.end.timeIntervalSince(range.start), 0.0999)
            range.setEnd(start.addingTimeInterval(offset))
            XCTAssertTrue(range.startOffsets.contains(range.startOffset))
            XCTAssertTrue(range.endOffsets.contains(range.endOffset))
            XCTAssertGreaterThanOrEqual(range.end.timeIntervalSince(range.start), 0.0999)
        }
        XCTAssertNil(AIReviewRange(began: start, ended: start, start: start, end: start))
    }
    func testLegacyReviewAndEndpointProvenanceAreBackwardCompatibleAndExcludeSecrets() throws {
        let value = try evidence(recording(words: ["hello"], duration: 1), duration: 1)
        let record = AIReviewRecord(evidence: value, goal: .combined, text: "uncertain", provider: .compatible, model: "m", language: "en", endpoint: "https://example.com/v1/chat/completions")
        XCTAssertEqual(try JSONDecoder().decode(AIReviewRecord.self, from: JSONEncoder().encode(record)).endpoint, record.endpoint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]); object.removeValue(forKey: "endpoint")
        XCTAssertNil(try JSONDecoder().decode(AIReviewRecord.self, from: JSONSerialization.data(withJSONObject: object)).endpoint)
        let unsafe = AIReviewRecord(evidence: value, goal: .body, text: "uncertain", provider: .compatible, model: "m", language: "en", endpoint: "https://secret@example.com/v1?key=secret")
        XCTAssertNil(unsafe.endpoint)
    }
}
