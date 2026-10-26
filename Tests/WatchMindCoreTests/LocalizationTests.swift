import XCTest
@testable import WatchMindCore

final class LocalizationTests: XCTestCase {
    func testExplicitLanguagesAndSystemFallback() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.english.speechLocaleIdentifier, "en-US")
        XCTAssertEqual(AppLanguage.simplifiedChinese.speechLocaleIdentifier, "zh-CN")
    }
    func testSwitchingLocalizersDoesNotRequireRestartOrMutateSource() {
        let en = Localizer(language: .english), zh = Localizer(language: .simplifiedChinese)
        XCTAssertEqual(en("现在"), "Now")
        XCTAssertEqual(zh("现在"), "现在")
        XCTAssertEqual(en("设置"), "Settings")
        XCTAssertEqual(zh.key("未识别到可用语音。"), "未识别到可用语音。")
        XCTAssertEqual(en.key("未识别到可用语音。"), "No usable speech was recognized.")
    }
    func testInterpolationTranslatesTemplateButDoesNotReinterpretUserText() {
        let l = Localizer(language: .english)
        let text = "私人文字 {0} 25% %@"
        XCTAssertEqual(l("以下文字线索尚未验证：\(text)"), "Unconfirmed language cues: " + text)
        XCTAssertEqual(l("\(98) 次/分"), "98 bpm")
        XCTAssertEqual(l("\(70) → \(105) 次/分。\(text)"), "70 → 105 bpm. " + text)
    }
    func testEnglishSummaryTranslatesLabelsNotPrivateTranscript() {
        var event = Episode(trigger: .init(date: Date(), bpm: 110, baseline: 70), status: .ready)
        event.transcript = "我今天很开心"; event.feeling = "愉快"
        let report = Insights.report(day: Date(), events: [event], language: .english)
        XCTAssertEqual(report.language, "en")
        XCTAssertTrue(report.text.contains("Today: 1 heart rate events"))
        XCTAssertTrue(report.text.contains("Feelings you confirmed: Happy"))
        XCTAssertTrue(report.text.contains(event.transcript))
        XCTAssertFalse(report.engine.contains("本地"))
    }
    func testEnglishSpeechTokensRetainWordBoundariesAndNegation() {
        let segments: [TranscriptSegment] = [
            .init(text: "not", offset: 0, duration: 0.3),
            .init(text: "happy", offset: 0.4, duration: 0.3),
            .init(text: "very", offset: 4, duration: 0.3),
            .init(text: "tired", offset: 4.4, duration: 0.4)
        ]
        let moments = Insights.moments(in: segments, language: .english)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].text, "very tired")
        XCTAssertEqual(moments[0].cues, ["Possible fatigue-related words"])
    }
    func testRecordingLanguageRoundtripAndLegacyArchive() throws {
        var event = Episode(trigger: .init(date: Date(), bpm: 110, baseline: 70))
        XCTAssertEqual(event.transcriptionLanguage, .simplifiedChinese)
        event.speechLanguage = "en"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: object)).transcriptionLanguage, .english)
        object.removeValue(forKey: "speechLanguage")
        XCTAssertEqual(try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: object)).transcriptionLanguage, .simplifiedChinese)
    }
}
