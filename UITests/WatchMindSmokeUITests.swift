import XCTest

/// Actual iOS UI automation. Requires an installed simulator runtime or real device.
/// No microphone, HealthKit, provider credentials, or destructive erase action is used.
final class WatchMindSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
    }

    func testPrimaryTabsAndPrivacySupportNavigation() {
        for title in ["Today", "Moments", "Review", "Mine"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists)
            tab.tap()
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        tapSettingsLink("privacy-center-link")
        XCTAssertTrue(app.otherElements["privacy-center-screen"].waitForExistence(timeout: 5)
                      || app.navigationBars["Privacy & data handling"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tapSettingsLink("support-center-link")
        XCTAssertTrue(app.otherElements["support-center-screen"].waitForExistence(timeout: 5)
                      || app.navigationBars["Help & support"].exists)
    }

    func testAISettingsCanOpenWithoutRequestingRecordingPermissions() {
        app.tabBars.buttons["Mine"].tap()
        tapSettingsLink("ai-settings-link")
        XCTAssertTrue(app.navigationBars["AI & model settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testHealthSignalsHaveAnAccessibleListAndMeaningfulLabels() {
        app.tabBars.buttons["Mine"].tap()
        tapSettingsLink("health-overview-link")
        let toggle = app.switches["health-signal-list-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let cell = app.buttons.matching(identifier: "health-signal-cell").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(cell.label.contains("No available clues") || cell.label.contains("Heart samples available") || cell.label.contains("Activity aggregate clues available"))
        XCTAssertGreaterThanOrEqual(cell.frame.height, 44)
        cell.tap()
        XCTAssertTrue(app.staticTexts["health-selected-signal"].exists)
    }

    private func tapSettingsLink(_ identifier: String) {
        let link = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<12 {
            if link.exists && link.isHittable { link.tap(); return }
            app.swipeUp()
        }
        XCTFail("Settings destination is missing or unreachable: " + identifier)
    }
}
