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

    /// A floating bar at the bottom of a scrolling document. On macOS 26 the bar
    /// joins the safe area, so content stops above it and the system scroll edge
    /// effect keeps text from showing through the glass behind its controls.
    @ViewBuilder
    func bardoBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            overlay(alignment: .bottom, content: bar)
        }
    }

    // IMPORTANT: SearchToolbarBehavior.minimize is explicitly unavailable on
    // macOS in the Xcode 26 SDK. Do not gate it with #available(macOS:); that
    // still fails to compile. For Bardo's macOS toolbar search, use SwiftUI
    // .searchable(..., placement: .toolbar) or bridge to NSSearchToolbarItem
    // when explicit collapsed/expanded AppKit behavior is required.

}