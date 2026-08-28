import SwiftUI

extension View {
    /// Uses native Liquid Glass on macOS 26 and a system-material fallback on older releases.
    @ViewBuilder
    func bardoGlassSurface(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.secondary.opacity(0.22), lineWidth: 0.5)
                }
        }
    }
}
