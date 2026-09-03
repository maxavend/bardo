import SwiftUI

/// Shared visual constants for Bardo's macOS interface.
enum BardoSpacing {
    static let detailHorizontal: CGFloat = 28
    static let detailTop: CGFloat = 20
    static let section: CGFloat = 22
    static let group: CGFloat = 12
    static let row: CGFloat = 8
}

enum BardoCornerRadius {
    static let compact: CGFloat = 6
    static let regular: CGFloat = 8
    static let panel: CGFloat = 8
    static let floating: CGFloat = 10
    static let setup: CGFloat = 16
    static let capsule: CGFloat = 18
}

enum BardoTypography {
    static let documentTitle = Font.title2.weight(.semibold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let label = Font.callout.weight(.medium)
    static let supporting = Font.caption
}
