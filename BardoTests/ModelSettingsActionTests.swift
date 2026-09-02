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

    func testQwenNotInstalledUsesOneOnDemandState() {
        let row = ModelSettingsRowState(
            id: .qwen,
            title: "Qwen",
            detail: "Downloads when needed",
            supportsInstallation: false,
            state: .notInstalled
        )

        XCTAssertEqual(row.stateLabel, String(localized: "Available on demand"))
    }

    func testNotInstalledModelUsesDownloadSymbolInsteadOfSelectionCircle() {
        let row = ModelSettingsRowState(
            id: .parakeet,
            title: "Parakeet",
            detail: "Fast transcription",
            supportsInstallation: true,
            state: .notInstalled
        )

        XCTAssertEqual(row.symbol, "arrow.down.circle")
    }

    func testInstallableNotInstalledRowDoesNotRepeatStatusBesideInstallAction() {
        let row = ModelSettingsRowState(
            id: .parakeet,
            title: "Parakeet",
            detail: "Fast transcription",
            supportsInstallation: true,
            state: .notInstalled
        )

        XCTAssertTrue(row.stateLabel.isEmpty)
    }
}
