import CoreGraphics
import XCTest
@testable import Bardo

final class LibraryLayoutTests: XCTestCase {
    func testLibraryShellUsesNativeMacOSProportions() {
        XCTAssertEqual(BardoLayout.librarySidebarMinWidth, 232)
        XCTAssertEqual(BardoLayout.librarySidebarIdealWidth, 252)
        XCTAssertEqual(BardoLayout.librarySidebarMaxWidth, 320)
        XCTAssertEqual(BardoLayout.libraryToolbarHeight, 52)
        XCTAssertEqual(BardoLayout.libraryDetailPadding, 24)
    }
}
