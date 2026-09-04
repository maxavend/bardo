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
}