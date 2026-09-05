import AppKit
import SwiftUI

/// Structural proportions shared by Bardo's native macOS shell.
///
/// Keep these values limited to layout constraints SwiftUI can't infer from
/// semantic controls. Visual styling and interaction states belong to macOS.
enum BardoLayout {
    static let librarySidebarMinWidth: CGFloat = 232
    static let librarySidebarIdealWidth: CGFloat = 252
    static let librarySidebarMaxWidth: CGFloat = 320
    static let libraryToolbarHeight: CGFloat = 52
    static let libraryWindowMinWidth: CGFloat = 960
    static let libraryWindowMinHeight: CGFloat = 600
    static let statusBannerMaxWidth: CGFloat = 720

    static let libraryDetailPadding: CGFloat = 24
    static let detailContentMaxWidth: CGFloat = 840
    static let emptyStateMinHeight: CGFloat = 320
    static let inlineUnavailableMinHeight: CGFloat = 240

    static let playbackMaxWidth: CGFloat = detailContentMaxWidth + 40
    static let playbackHorizontalPadding: CGFloat = libraryDetailPadding
    static let playbackBottomPadding: CGFloat = 18
    static let playbackSurfaceHeight: CGFloat = 58
    static let playbackContentClearance: CGFloat = 96
    static let followLiveGapAbovePlayback: CGFloat = 10

    static let informationSheetWidth: CGFloat = 480
    static let informationSheetHeight: CGFloat = 580
    static let renameSheetWidth: CGFloat = 420
    static let recoverySheetMinWidth: CGFloat = 560
    static let recoverySheetIdealHeight: CGFloat = 360
    static let recoverySheetMaxHeight: CGFloat = 620

    static let settingsMinWidth: CGFloat = 620
    static let settingsMinHeight: CGFloat = 540
}

enum BardoSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let compact: CGFloat = 12
    static let standard: CGFloat = 16
    static let section: CGFloat = 20
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32

    static let detailHorizontal: CGFloat = BardoLayout.libraryDetailPadding
    static let detailHeaderTop: CGFloat = large
    static let detailHeaderBottom: CGFloat = standard
    static let detailBodyTop: CGFloat = 0
    static let sheet: CGFloat = large
}

enum BardoCornerRadius {
    /// Reserved for the one legitimate floating glass control: playback.
    static let floating: CGFloat = 12
}

struct BardoDetailBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                (colorScheme == .dark ? Color.black.opacity(0.07) : Color.black.opacity(0.025))
            }
    }
}

struct BardoEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    let footnote: String?
    private let actions: Actions

    init(
        systemImage: String,
        title: String,
        detail: String,
        footnote: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: BardoSpacing.standard) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(minHeight: 38)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            actions

            if let footnote {
                Label(footnote, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: BardoLayout.emptyStateMinHeight,
            alignment: .top
        )
        .padding(.top, 48)
        .padding(.bottom, BardoSpacing.large)
    }
}
