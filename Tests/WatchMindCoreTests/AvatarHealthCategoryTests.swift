import Foundation
import XCTest
@testable import WatchMindCore

final class AvatarHealthCategoryTests: XCTestCase {
    func testLegacyAvatarKeepsExistingSelections() throws {
        let old = Data(#"{"name":"Me","hair":"curls","accessory":"glasses","skin":3,"outfit":2,"hairColor":1}"#.utf8)
        let avatar = try JSONDecoder().decode(AvatarConfiguration.self, from: old)
        XCTAssertEqual(avatar.style, .human)
        XCTAssertEqual(avatar.name, "Me")
        XCTAssertEqual(avatar.hair, .curls)
        XCTAssertEqual(avatar.accessory, .glasses)
        XCTAssertEqual(avatar.skin, 3)
        XCTAssertEqual(avatar.outfit, 2)
        XCTAssertEqual(avatar.hairColor, 1)
    }
    func testNewStylesRoundTripWithoutChangingUserConfiguration() throws {
        for style in AvatarConfiguration.Style.allCases {
            var avatar = AvatarConfiguration.preset(style)
            avatar.hair = .bald; avatar.accessory = .cap; avatar.skin = 5; avatar.outfit = 5
            XCTAssertEqual(try JSONDecoder().decode(AvatarConfiguration.self, from: JSONEncoder().encode(avatar)), avatar)
        }
    }
    func testDecodeBoundsInvalidPaletteAndName() throws {
        let data = Data(#"{"skin":-10,"outfit":999,"hairColor":-1,"name":"abcdefghijklmnopqrstuvwxyz"}"#.utf8)
        let avatar = try JSONDecoder().decode(AvatarConfiguration.self, from: data)
        XCTAssertEqual(avatar.skin, 0); XCTAssertEqual(avatar.outfit, 5); XCTAssertEqual(avatar.hairColor, 0)
        XCTAssertEqual(avatar.name.count, 20)
        XCTAssertEqual(avatar.hair, .bob)
    }
    func testEachMetricHasExactlyOneCategoryAndHeartIsCardio() {
        let all = HealthCategory.allCases.flatMap(\.metricKinds)
        XCTAssertEqual(Set(all), Set(MetricKind.allCases))
        XCTAssertEqual(all.count, MetricKind.allCases.count)
        XCTAssertEqual(HealthCategory.allCases.filter(\.includesHeart), [.cardio])
        XCTAssertEqual(MetricKind.hrv.category, .cardio)
        XCTAssertEqual(MetricKind.steps.category, .activity)
        XCTAssertEqual(MetricKind.wristTemperature.category, .recovery)
        XCTAssertEqual(MetricKind.headphoneAudio.category, .environment)
        XCTAssertTrue(HealthCategory.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
    }
}
