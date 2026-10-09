import AppKit
import SwiftUI

/// Structural proportions shared by the native macOS library shell.
///
/// Keep these values limited to constraints SwiftUI cannot infer from the
/// semantic controls themselves. Visual styling belongs to the system.
enum BardoLayout {
    static let windowMinWidth: CGFloat = 980
    static let windowMinHeight: CGFloat = 620
    static let windowDefaultWidth: CGFloat = 1240
    static let librarySidebarMinWidth: CGFloat = 190
    static let librarySidebarIdealWidth: CGFloat = 220
    static let librarySidebarMaxWidth: CGFloat = 300
    static let listColumnMinWidth: CGFloat = 260
    static let listColumnIdealWidth: CGFloat = 310
    static let listColumnMaxWidth: CGFloat = 460
    static let detailColumnMinWidth: CGFloat = 420
    static let inspectorMinWidth: CGFloat = 250
    static let inspectorIdealWidth: CGFloat = 290
    static let inspectorMaxWidth: CGFloat = 380
    static let libraryDetailPadding: CGFloat = 28
    /// Keeps transcript lines near a comfortable reading measure.
    static let detailContentMaxWidth: CGFloat = 720

    static let playbackMaxWidth: CGFloat = 720
    static let playbackHorizontalPadding: CGFloat = 20
    static let playbackBottomPadding: CGFloat = 16
    static let playbackSurfaceHeight: CGFloat = 58
    static let playbackContentClearance: CGFloat = 96
    static let followLiveGapAbovePlayback: CGFloat = 8
}

enum BardoSpacing {
    static let detailHorizontal: CGFloat = BardoLayout.libraryDetailPadding
    static let section: CGFloat = 20
}

enum BardoCornerRadius {
    /// Reserved for the one legitimate floating glass control: playback.
    static let floating: CGFloat = 12
}
