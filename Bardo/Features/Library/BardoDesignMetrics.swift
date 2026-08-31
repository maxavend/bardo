import SwiftUI

enum BardoDesignMetrics {
    // Reading and chrome deliberately use different widths. The transcript should
    // remain comfortable to read even when the window grows substantially.
    static let readableTranscriptWidth: CGFloat = 740
    static let detailChromeWidth: CGFloat = 920

    // A compact spacing scale keeps rhythm consistent without introducing a
    // heavyweight design-token layer for a small native macOS app.
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 18
    static let spacingXL: CGFloat = 24

    static let detailHorizontalPadding: CGFloat = 30
    static let detailTopPadding: CGFloat = 20
    static let transcriptBlockSpacing: CGFloat = 10
    static let compactCornerRadius: CGFloat = 10
    static let floatingCornerRadius: CGFloat = 22
    static let minimumUsefulDetailWidth: CGFloat = 430
}
