import XCTest
@testable import Bardo

final class ModelSettingsActionTests: XCTestCase {
    func testNotInstalledModelCanBeInstalled() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .notInstalled, supportsInstallation: true),
            .install
        )
    }

    func testActiveModelDownloadCanBeCancelled() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .downloading(0.4), supportsInstallation: true),
            .cancel
        )
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .preparing(0.8), supportsInstallation: true),
            .cancel
        )
    }

    func testFailedModelCanRetryOrReset() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .failed("network"), supportsInstallation: true),
            .retry
        )
    }

    func testQwenWithoutStandaloneInstallerExplainsItsLifecycle() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .notInstalled, supportsInstallation: false),
            .unavailable
        )
    }
}
