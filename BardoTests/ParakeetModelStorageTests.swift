import Foundation
import XCTest
@testable import Bardo

final class ParakeetModelStorageTests: XCTestCase {
    func testParakeetUsesBardoOwnedApplicationSupportDirectory() {
        let directory = ParakeetTranscriptionService.modelDirectory.standardizedFileURL
        let path = directory.path

        XCTAssertTrue(path.contains("/Bardo/Models/Parakeet/"), path)
        XCTAssertEqual(directory.lastPathComponent, ParakeetTranscriptionService.modelID)
        XCTAssertFalse(path.contains("/FluidAudio/Models/"), path)
    }
}
