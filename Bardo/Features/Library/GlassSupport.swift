import SwiftUI

extension View {
    /// Applies Liquid Glass only to a genuinely floating interactive control.
    ///
    /// Bardo deliberately avoids custom glass for navigation, toolbars,
    /// content cards, forms, and buttons because native SwiftUI controls
    /// receive the platform appearance automatically.
    @ViewBuilder
    func bardoGlassSurface(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    /// A stable Apple Music-like playback surface. The glass container itself
    /// is intentionally non-interactive so button presses never scale or morph
    /// the whole player.
    @ViewBuilder
    func bardoPlaybackSurface() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.separator.opacity(0.25), lineWidth: 0.5)
                }
        }
    }

    // IMPORTANT: SearchToolbarBehavior.minimize is explicitly unavailable on
    // macOS in the Xcode 26 SDK. Do not gate it with #available(macOS:); that
    // still fails to compile. For Bardo's macOS toolbar search, use SwiftUI
    // .searchable(..., placement: .toolbar) or bridge to NSSearchToolbarItem
    // when explicit collapsed/expanded AppKit behavior is required.

}