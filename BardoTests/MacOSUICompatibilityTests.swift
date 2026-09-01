import XCTest
@testable import Bardo

final class MacOSUICompatibilityTests: XCTestCase {
    func testNativeToolbarIsAllowedBeforeMacOS27() {
        XCTAssertTrue(
            MacOSUICompatibility.usesNativeToolbar(
                for: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
            )
        )
    }

    func testNativeToolbarIsDisabledOnMacOS27AndLater() {
        XCTAssertFalse(
            MacOSUICompatibility.usesNativeToolbar(
                for: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            )
        )
        XCTAssertFalse(
            MacOSUICompatibility.usesNativeToolbar(
                for: OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)
            )
        )
    }
}
