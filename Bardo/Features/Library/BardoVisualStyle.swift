import AppKit
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
    static let detailContentMaxWidth: CGFloat = 800
    static let emptyStateMinHeight: CGFloat = 340

    static let playbackMaxWidth: CGFloat = 820
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
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(height: 38)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .frame(height: 24)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .frame(height: 42, alignment: .top)
            }

            actions
                .frame(height: 32)

            Group {
                if let footnote {
                    Label(footnote, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(height: 18)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: BardoLayout.emptyStateMinHeight,
            alignment: .top
        )
        .padding(.top, 54)
        .padding(.bottom, 24)
    }
}
