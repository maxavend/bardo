import SwiftUI

/// Structural proportions shared by the native macOS library shell.
///
/// Keep these values limited to constraints SwiftUI cannot infer from the
/// semantic controls themselves. Visual styling belongs to the system.
enum BardoLayout {
    static let librarySidebarMinWidth: CGFloat = 220
    static let librarySidebarIdealWidth: CGFloat = 240
    static let librarySidebarMaxWidth: CGFloat = 300
    static let libraryToolbarHeight: CGFloat = 52
    static let libraryDetailPadding: CGFloat = 20
    static let playbackContentClearance: CGFloat = 96
}

enum BardoSpacing {
    static let detailHorizontal: CGFloat = BardoLayout.libraryDetailPadding
    static let section: CGFloat = 20
}

enum BardoCornerRadius {
    /// Reserved for the one legitimate floating glass control: playback.
    static let floating: CGFloat = 12
}