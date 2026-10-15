import CoreGraphics
import XCTest
@testable import Bardo

final class LibraryLayoutTests: XCTestCase {
    /// Details open as a sheet, so the sidebar, the list and a readable transcript must
    /// fit side by side even in the smallest window.
    func testEveryColumnFitsTheMinimumWindow() {
        let columns = BardoLayout.librarySidebarIdealWidth
            + BardoLayout.listColumnMinWidth
            + BardoLayout.detailColumnMinWidth
        XCTAssertLessThanOrEqual(columns, BardoLayout.windowMinWidth)
    }

    func testColumnWidthRangesAreOrdered() {
        XCTAssertLessThan(BardoLayout.librarySidebarMinWidth, BardoLayout.librarySidebarMaxWidth)
        XCTAssertLessThan(BardoLayout.listColumnMinWidth, BardoLayout.listColumnMaxWidth)
    }
}
