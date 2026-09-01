import XCTest
@testable import Bardo

final class SpeakerModelRepairPolicyTests: XCTestCase {
    private enum TestFailure: Error {
        case loadFailed
    }

    func testRepairsPreviouslyInstalledModelAfterLoadFailure() {
        XCTAssertTrue(
            SpeakerModelRepairPolicy.shouldRepair(
                hadInstalledModels: true,
                error: TestFailure.loadFailed,
                taskIsCancelled: false
            )
        )
    }

    func testDoesNotRepairFirstDownloadFailure() {
        XCTAssertFalse(
            SpeakerModelRepairPolicy.shouldRepair(
                hadInstalledModels: false,
                error: TestFailure.loadFailed,
                taskIsCancelled: false
            )
        )
    }

    func testDoesNotRepairCancellationError() {
        XCTAssertFalse(
            SpeakerModelRepairPolicy.shouldRepair(
                hadInstalledModels: true,
                error: CancellationError(),
                taskIsCancelled: false
            )
        )
    }

    func testDoesNotRepairWhenTaskIsCancelled() {
        XCTAssertFalse(
            SpeakerModelRepairPolicy.shouldRepair(
                hadInstalledModels: true,
                error: TestFailure.loadFailed,
                taskIsCancelled: true
            )
        )
    }
}
