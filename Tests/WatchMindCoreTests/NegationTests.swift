import XCTest
@testable import WatchMindCore

final class NegationTests: XCTestCase {
    func testChineseNegationsDoNotBecomePositiveCues() {
        for text in ["我今天不开心", "现在不紧张了", "没有压力", "没什么压力", "不太开心", "不再觉得紧张", "不累了"] {
            XCTAssertTrue(Insights.cues(in: text).isEmpty, text)
        }
    }
    func testEnglishNegationAndWordBoundaries() {
        for text in ["I am unhappy", "I am not happy", "I am not really happy", "I'm not stressed", "I wasn't very worried", "tiredness"] {
            XCTAssertTrue(Insights.cues(in: text).isEmpty, text)
        }
    }
    func testAffirmativeClauseStillRecognizedAfterNegatedClause() {
        XCTAssertEqual(Insights.cues(in: "之前不开心，现在很开心"), ["可能涉及愉快"])
        XCTAssertEqual(Insights.cues(in: "I was not happy, but now I am excited"), ["可能涉及愉快"])
        XCTAssertEqual(Insights.cues(in: "没有压力，但今天有点累"), ["可能涉及疲劳"])
    }
    func testAmbiguousCharacterSubstringsDoNotSuggestFatigue() {
        XCTAssertTrue(Insights.cues(in: "这个方案有困难，需要积累经验").isEmpty)
    }
    func testAffirmativeCuesArePreserved() {
        XCTAssertEqual(Set(Insights.cues(in: "我很紧张，也很期待，今天有点累")),
                       Set(["可能涉及压力", "可能涉及愉快", "可能涉及疲劳"]))
    }
}
