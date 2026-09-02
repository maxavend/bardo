import XCTest
@testable import Bardo

final class ManagedModelStateTests: XCTestCase {
    func testManagedModelListsTheSupportedModels() {
        XCTAssertEqual(
            ManagedModel.allCases,
            [.whisperBalanced, .whisperMaximumAccuracy, .parakeet, .speakerKit, .qwen]
        )
    }

    func testManagedModelStateIsEquatableAcrossAssociatedValues() {
        XCTAssertEqual(ManagedModelState.notInstalled, .notInstalled)
        XCTAssertEqual(ManagedModelState.downloading(0.5), .downloading(0.5))
        XCTAssertEqual(ManagedModelState.preparing(0.75), .preparing(0.75))
        XCTAssertEqual(ManagedModelState.installed, .installed)
        XCTAssertEqual(ManagedModelState.failed("network"), .failed("network"))

        XCTAssertNotEqual(ManagedModelState.downloading(0.5), .preparing(0.5))
        XCTAssertNotEqual(ManagedModelState.failed("network"), .failed("disk"))
    }
}
