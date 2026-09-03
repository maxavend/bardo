import SwiftUI

extension View {
    /// Uses native Liquid Glass on macOS 26 and a system-material fallback on older releases.
    @ViewBuilder
    func bardoGlassSurface(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    /// Uses native Liquid Glass capsule on macOS 26 and a system-material fallback on older releases.
    @ViewBuilder
    func bardoGlassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .capsule
            )
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
    }
}
