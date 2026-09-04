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

    /// Uses native Liquid Glass circle on macOS and a system-material fallback.
    @ViewBuilder
    func bardoGlassCircle(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .circle
            )
        } else {
            self
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
    }
}

/// A tactile button style that subtly scales on press (scale 0.97) for immediate direct manipulation feedback.
struct BardoPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BardoPressableButtonStyle {
    static var bardoPressable: BardoPressableButtonStyle {
        BardoPressableButtonStyle()
    }
}
