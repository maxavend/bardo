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

    func testFailedModelCanRetry() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .failed("network"), supportsInstallation: true),
            .retry
        )
    }

    func testInstalledVoiceModelUsesManagementMenu() {
        let row = ModelSettingsRowState(
            id: .whisperTurbo,
            title: "Transcripción",
            detail: "Private transcription download",
            supportsInstallation: true,
            state: .installed
        )

        XCTAssertEqual(row.primaryAction, .reset)
        XCTAssertEqual(row.stateLabel, String(localized: "Installed"))
        XCTAssertNil(row.progressFraction)
    }

    func testRuntimeVoiceModelUsesDownloadAction() {
        let row = ModelSettingsRowState(
            id: .whisperTurbo,
            title: "Transcripción",
            detail: "Private transcription download",
            supportsInstallation: true,
            state: .notInstalled
        )

        XCTAssertEqual(row.primaryAction, .install)
        XCTAssertEqual(row.stateLabel, "")
    }
}
