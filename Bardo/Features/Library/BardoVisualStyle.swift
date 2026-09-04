import SwiftUI

/// Shared proportions for the macOS library shell.
enum BardoLayout {
    static let librarySidebarMinWidth: CGFloat = 240
    static let librarySidebarIdealWidth: CGFloat = 260
    static let librarySidebarMaxWidth: CGFloat = 320
    static let libraryToolbarHeight: CGFloat = 52
    static let libraryDetailPadding: CGFloat = 24
}

/// Shared visual constants for Bardo's macOS interface.
enum BardoSpacing {
    static let detailHorizontal: CGFloat = BardoLayout.libraryDetailPadding
    static let detailTop: CGFloat = 16
    static let section: CGFloat = 20
    static let group: CGFloat = 12
    static let row: CGFloat = 6
}

enum BardoCornerRadius {
    static let compact: CGFloat = 6
    static let regular: CGFloat = 8
    static let panel: CGFloat = 10
    static let floating: CGFloat = 12
    static let setup: CGFloat = 16
    static let capsule: CGFloat = 16
}

enum BardoTypography {
    static let documentTitle = Font.title3.weight(.semibold)
    static let sectionTitle = Font.headline
    static let label = Font.subheadline.weight(.medium)
    static let supporting = Font.caption
    static let shellTitle = Font.headline
    static let shellSubtitle = Font.subheadline
}
