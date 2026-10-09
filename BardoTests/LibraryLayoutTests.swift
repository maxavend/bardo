import CoreGraphics
import XCTest
@testable import Bardo

final class LibraryLayoutTests: XCTestCase {
    /// With the inspector open the window hides the sidebar when space is short; the
    /// list, a readable transcript and the inspector must still fit the smallest window.
    func testInspectorFitsTheMinimumWindowWithoutTheSidebar() {
        let columns = BardoLayout.listColumnMinWidth
            + BardoLayout.detailColumnMinWidth
            + BardoLayout.inspectorMinWidth
        XCTAssertLessThanOrEqual(columns, BardoLayout.windowMinWidth)
    }

    /// At the default window size every column, sidebar included, fits at once.
    func testEveryColumnFitsTheDefaultWindow() {
        let columns = BardoLayout.librarySidebarIdealWidth
            + BardoLayout.listColumnMinWidth
            + BardoLayout.detailColumnMinWidth
            + BardoLayout.inspectorMinWidth
        XCTAssertLessThanOrEqual(columns, BardoLayout.windowDefaultWidth)
    }

    func testColumnWidthRangesAreOrdered() {
        XCTAssertLessThan(BardoLayout.librarySidebarMinWidth, BardoLayout.librarySidebarMaxWidth)
        XCTAssertLessThan(BardoLayout.listColumnMinWidth, BardoLayout.listColumnMaxWidth)
        XCTAssertLessThan(BardoLayout.inspectorMinWidth, BardoLayout.inspectorMaxWidth)
    }
}
