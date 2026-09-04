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

    func testMeetingMinutesModelCanBeInstalledDuringSetupOrRetry() {
        XCTAssertEqual(
            ModelSettingsActionPolicy.action(for: .notInstalled, supportsInstallation: true),
            .install
        )
    }

    func testMeetingMinutesModelUsesDownloadState() {
        let row = ModelSettingsRowState(
            id: .meetingMinutes,
            title: "Meeting Minutes",
            detail: "Downloaded during first-run setup for on-device generation.",
            supportsInstallation: true,
            state: .notInstalled
        )

        XCTAssertEqual(row.stateLabel, "")
    }

    func testRuntimeVoiceModelUsesDownloadAction() {
        let row = ModelSettingsRowState(
            id: .whisperTurbo,
            title: "Whisper Turbo",
            detail: "Private transcription download",
            supportsInstallation: true,
            state: .notInstalled
        )

        XCTAssertEqual(row.primaryAction, .install)
        XCTAssertNotEqual(row.stateLabel, String(localized: "On demand"))
    }
}
