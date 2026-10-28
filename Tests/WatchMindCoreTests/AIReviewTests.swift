import XCTest
@testable import WatchMindCore

final class AIReviewTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func owner(demo: Bool = false) -> Episode {
        var owner = Episode(trigger: .init(date: start, bpm: 90, baseline: 70), status: .ready, isDemo: demo)
        owner.captureStarted = start; owner.captureEnded = start.addingTimeInterval(100)
        owner.audioName = "private-original.m4a"
        owner.recordingParts = [.init(audioName: "a.m4a", startedAt: start, endedAt: start.addingTimeInterval(30)),
                                .init(audioName: "b.m4a", startedAt: start.addingTimeInterval(60), endedAt: start.addingTimeInterval(100))]
        owner.segments = [.init(text: "before", offset: 2, duration: 5), .init(text: "boundary utterance", offset: 8, duration: 6),
                          .init(text: "gap must not be quoted", offset: 45, duration: 2), .init(text: "later", offset: 70, duration: 5)]
        owner.transcript = "WHOLE PRIVATE TRANSCRIPT SHOULD NEVER BE SENT"
        return owner
    }
    func selection(_ owner: Episode, from: Double = 10, to: Double = 80) -> AIReviewSelection {
        .init(recordingID: owner.id, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to))
    }
    func testArbitraryRangePreservesWholeBoundaryUtteranceAndRealGaps() throws {
        let owner = owner()
        let evidence = try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        XCTAssertEqual(evidence.transcript.map(\.text), ["boundary utterance", "later"])
        XCTAssertEqual(evidence.transcript.first?.start, start.addingTimeInterval(8))
        XCTAssertEqual(evidence.audioWindows.count, 2)
        XCTAssertEqual(evidence.audioWindows[0].start, start.addingTimeInterval(10))
        XCTAssertEqual(evidence.audioWindows[0].end, start.addingTimeInterval(30))
        XCTAssertEqual(evidence.audioWindows[1].start, start.addingTimeInterval(60))
        XCTAssertEqual(evidence.audioWindows[1].end, start.addingTimeInterval(80))
        let preview = try evidence.preview
        XCTAssertFalse(preview.contains("private-original")); XCTAssertFalse(preview.contains("a.m4a"))
        XCTAssertFalse(preview.contains(owner.transcript)); XCTAssertFalse(preview.contains("before"))
    }
    func testLinkedSelectionResolvesOwnerAndCannotReadOtherDemoPartition() throws {
        let owner = owner()
        var linked = Episode(trigger: .init(date: start.addingTimeInterval(15), bpm: 110, baseline: 70), status: .linked)
        linked.linkedRecordingID = owner.id
        let evidence = try AIReviewEvidence.build(selection: selection(linked), episodes: [owner, linked], heartPoints: [], metrics: [], isDemo: false)
        XCTAssertEqual(evidence.recordingID, owner.id)
        XCTAssertThrowsError(try AIReviewEvidence.build(selection: selection(linked), episodes: [owner, linked], heartPoints: [], metrics: [], isDemo: true)) {
            XCTAssertEqual($0 as? AIReviewError, .sourceUnavailable)
        }
    }
    func testHealthOnlyHonorsSelectedKindsTimeWindowValidityAndDemoScope() throws {
        let within = start.addingTimeInterval(30)
        let points: [HeartPoint] = [.init(sample: .init(date: within, bpm: 80), baseline: 70),
                                    .init(sample: .init(date: within, bpm: 150), isDemo: true),
                                    .init(sample: .init(date: start.addingTimeInterval(100), bpm: 90)),
                                    .init(sample: .init(date: within, bpm: .nan))]
        let data: [MetricReading] = [.init(kind: .hrv, value: 50, date: within, source: "Watch"),
                                     .init(kind: .oxygen, value: 98, date: within, source: "Watch"),
                                     .init(kind: .hrv, value: -1, date: within, source: "invalid"),
                                     .init(kind: .hrv, value: 45, date: start.addingTimeInterval(-30), source: "prior"),
                                     .init(kind: .hrv, value: 30, date: start.addingTimeInterval(-86400), source: "stale")]
        let selection = AIReviewSelection(start: start, end: start.addingTimeInterval(60), includeTranscript: false, metricKinds: [.hrv, .hrv])
        let evidence = try AIReviewEvidence.build(selection: selection, episodes: [], heartPoints: points, metrics: data, isDemo: false)
        XCTAssertEqual(evidence.heartPoints.count, 1); XCTAssertEqual(evidence.heartPoints.first?.sample.bpm, 80)
        XCTAssertEqual(evidence.metrics.map(\.source), ["prior", "Watch"])
        XCTAssertEqual(evidence.selection.metricKinds, [.hrv]); XCTAssertNil(evidence.recordingID)
    }
    func testUnavailableEvidenceIsNotInventedFromUnalignedLegacyTranscript() {
        var owner = owner(); owner.segments = []
        XCTAssertThrowsError(try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)) {
            XCTAssertEqual($0 as? AIReviewError, .emptyEvidence)
        }
    }
    func testBaselineUsesComparableNamedSourceAndIsClearlyHistorical() throws {
        var data: [MetricReading] = [.init(kind: .hrv, value: 60, date: start, source: "Watch A")]
        for day in 1...6 {
            data.append(.init(kind: .hrv, value: 50, date: start.addingTimeInterval(Double(day) * -86400), source: "Watch A"))
            data.append(.init(kind: .hrv, value: 400, date: start.addingTimeInterval(Double(day) * -86400), source: "Different source"))
        }
        let selection = AIReviewSelection(start: start, end: start.addingTimeInterval(60), includeTranscript: false, includeHeart: false, metricKinds: [.hrv])
        let evidence = try AIReviewEvidence.build(selection: selection, episodes: [], heartPoints: [], metrics: data, isDemo: false)
        XCTAssertEqual(evidence.baselines.first?.median, 50)
        XCTAssertEqual(evidence.baselines.first?.source, "Watch A")
        XCTAssertEqual(evidence.baselines.first?.before, start)
        XCTAssertEqual(evidence.metrics.count, 1)
    }
    func testInvalidAndExcessiveRangesAndPayloadAreRejectedRatherThanTruncated() {
        var owner = owner()
        for end in [start, start.addingTimeInterval(-1), start.addingTimeInterval(86401)] {
            let range = AIReviewSelection(start: start, end: end, includeTranscript: false)
            XCTAssertThrowsError(try AIReviewEvidence.build(selection: range, episodes: [], heartPoints: [], metrics: [], isDemo: false)) {
                XCTAssertEqual($0 as? AIReviewError, .invalidWindow)
            }
        }
        owner.segments = [.init(text: String(repeating: "s", count: 25_000), offset: 15, duration: 5)]
        XCTAssertThrowsError(try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)) {
            XCTAssertEqual($0 as? AIReviewError, .tooMuchEvidence)
        }
    }
    func testEndpointValidationAndCompatibleRoute() throws {
        XCTAssertEqual(try AIConfiguration.preset(.openAI).chatCompletionsURL().absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try AIConfiguration(provider: .compatible, baseURL: "https://example.com/custom/v1/", model: "model").chatCompletionsURL().absoluteString,
                       "https://example.com/custom/v1/chat/completions")
        XCTAssertEqual(try AIConfiguration(provider: .compatible, baseURL: "https://example.com/v1/chat/completions", model: "model").chatCompletionsURL().path,
                       "/v1/chat/completions")
        XCTAssertEqual(try AIConfiguration(provider: .compatible, baseURL: "https://example.com/v1/chat/completions/", model: "model").chatCompletionsURL().path,
                       "/v1/chat/completions")
        XCTAssertNoThrow(try AIConfiguration.preset(.localEndpoint).chatCompletionsURL())
        for endpoint in ["http://example.com/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/v1", "https://example.com/v1#secret"] {
            XCTAssertThrowsError(try AIConfiguration(provider: .compatible, baseURL: endpoint, model: "m").chatCompletionsURL())
        }
        XCTAssertThrowsError(try AIConfiguration(provider: .localEndpoint, baseURL: "https://remote.example/v1", model: "m").chatCompletionsURL())
        XCTAssertThrowsError(try AIConfiguration(provider: .openAI, baseURL: "https://example.com/v1", model: "").chatCompletionsURL())
    }
    func testPromptUsesExactPreviewAndMakesHealthAndAcousticLimitsExplicit() throws {
        let owner = owner()
        let evidence = try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        let messages = try AIReviewPrompt.messages(evidence: evidence, goal: .combined, language: .english)
        XCTAssertEqual(messages[1].content, try evidence.preview)
        XCTAssertTrue(messages[0].content.contains("Never diagnose")); XCTAssertTrue(messages[0].content.contains("No raw audio"))
        XCTAssertTrue(messages[0].content.contains("untrusted data")); XCTAssertTrue(messages[0].content.contains("whole utterances"))
        let request = try OpenAIReviewCodec.request(configuration: .preset(.deepSeek), messages: messages)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertNil(object["api_key"])
    }
    func testCompatibleResponseValidatesEmptyOversizedAndTruncatedContent() throws {
        func response(_ text: String, reason: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": reason]]])
        }
        XCTAssertEqual(try OpenAIReviewCodec.response(response("  analysis  ")), "analysis")
        for text in ["", "   "] { XCTAssertThrowsError(try OpenAIReviewCodec.response(response(text))) }
        XCTAssertThrowsError(try OpenAIReviewCodec.response(response("partial", reason: "length")))
        XCTAssertThrowsError(try OpenAIReviewCodec.response(response(String(repeating: "a", count: 12_001))))
        XCTAssertThrowsError(try OpenAIReviewCodec.response(Data(repeating: 1, count: 256_001)))
    }
    func testConfigurationAndSavedReviewCodableNeverContainCredentials() throws {
        let owner = owner()
        let evidence = try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        let record = AIReviewRecord(evidence: evidence, goal: .intent, text: "A tentative interpretation", provider: .apple, model: "system", language: "en")
        let decoded = try JSONDecoder().decode(AIReviewRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.id, record.id); XCTAssertEqual(decoded.evidence.transcript.count, 2)
        let config = String(decoding: try JSONEncoder().encode(AIConfiguration.preset(.openAI)), as: UTF8.self)
        XCTAssertFalse(config.contains("apiKey")); XCTAssertFalse(config.contains("api_key"))
    }
    func testLegacyArchiveDefaultsToEmptyReviewsAndNewRecordsRoundTrip() throws {
        let archive = try JSONDecoder().decode(JournalArchive.self, from: Data(#"{"version":1,"episodes":[],"reports":[]}"#.utf8))
        XCTAssertTrue(archive.reviews.isEmpty)
        let owner = owner()
        let evidence = try AIReviewEvidence.build(selection: selection(owner), episodes: [owner], heartPoints: [], metrics: [], isDemo: false)
        let record = AIReviewRecord(evidence: evidence, goal: .body, text: "Uncertain", provider: .apple, model: "system", language: "en")
        let saved = JournalArchive(episodes: [owner], reviews: [record])
        XCTAssertEqual(try JSONDecoder().decode(JournalArchive.self, from: JSONEncoder().encode(saved)).reviews.first?.id, record.id)
    }
}
