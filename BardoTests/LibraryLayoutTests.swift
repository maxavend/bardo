import CoreGraphics
import XCTest
@testable import Bardo

final class LibraryLayoutTests: XCTestCase {
    func testLibraryShellUsesNativeMacOSProportions() {
        XCTAssertEqual(BardoLayout.librarySidebarMinWidth, 220)
        XCTAssertEqual(BardoLayout.librarySidebarIdealWidth, 240)
        XCTAssertEqual(BardoLayout.librarySidebarMaxWidth, 300)
        XCTAssertEqual(BardoLayout.libraryToolbarHeight, 52)
        XCTAssertEqual(BardoLayout.libraryDetailPadding, 20)
    }
}
