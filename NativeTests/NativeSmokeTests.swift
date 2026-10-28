import XCTest
@testable import WatchMind
import WatchMindCore

final class NativeSmokeTests: XCTestCase {
    func testPublisherLinksRequirePublicHTTPSWithoutCredentials() {
        XCTAssertNotNil(PublisherConfiguration.validatedPublicURL("https://watchmind.app/privacy"))
        for raw in ["", "$(WATCHMIND_PRIVACY_POLICY_URL)", "http://watchmind.app/privacy", "https://localhost/privacy",
                    "https://example.com/privacy", "https://publisher.invalid/privacy", "https://token@watchmind.app/privacy", "https://127.0.0.1/privacy",
                    "https://watchmind.app/privacy?key=secret", "file:///private/privacy"] {
            XCTAssertNil(PublisherConfiguration.validatedPublicURL(raw), "Invalid publisher link was accepted")
        }
    }

    /// Uses a unique fake credential in the real native Keychain, never a provider or network.
    @MainActor func testNativeKeychainCredentialRoundTripStaysOutOfExportableConfiguration() throws {
        let settings = AISettings()
        let original = settings.configuration
        settings.configuration = AIConfiguration(provider: .compatible,
            baseURL: "https://native-smoke.invalid/" + UUID().uuidString + "/v1", model: "fixture")
        defer { try? settings.deleteKey(); settings.configuration = original }
        XCTAssertFalse(settings.keyAvailable)
        let fixture = "native-smoke-fixture-" + UUID().uuidString
        try settings.saveKey(fixture)
        XCTAssertTrue(settings.keyAvailable)
        settings.reloadKeyStatus()
        XCTAssertTrue(settings.keyAvailable)
        let exportable = String(decoding: try JSONEncoder().encode(settings.configuration), as: UTF8.self)
        XCTAssertFalse(exportable.contains(fixture))
        try settings.deleteKey()
        XCTAssertFalse(settings.keyAvailable)
    }
}
