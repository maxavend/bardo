import XCTest
@testable import Bardo

final class BootstrapTests: XCTestCase {
    @MainActor
    func testRootViewCanBeConstructed() {
        _ = RootView()
    }
}
