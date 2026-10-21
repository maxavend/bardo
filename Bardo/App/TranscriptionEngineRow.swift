import SwiftUI

/// One way of transcribing in Settings: what it is good for, who makes it and how much
/// it takes, whether it is the one in use, and what can be done with it.
struct TranscriptionEngineRow: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    /// The download behind it; Apple's lives in macOS and has none.
    let managedRow: ModelSettingsRowState?
    let isAppleReady: Bool
    let isPreparingApple: Bool
    let appleFailure: String?
    let select: () -> Void
    let action: (ModelSettingsAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(engine.title)
                        .fontWeight(.semibold)
                    if engine == .recommended {
                        RecommendedBadge()
                    }
                }
                Text(engine.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let progress = managedRow?.progressFraction {
                    ProgressView(value: progress)
                        .padding(.top, 4)
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .opacity(engine.isSupported ? 1 : 0.55)
        // The whole row chooses it, once it can be used.
        .contentShape(.rect)
        .onTapGesture {
            if isInstalled, !isSelected { select() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Who makes it and what it takes, said once.
    private var caption: String {
        guard engine.isSupported else { return "Requiere macOS 26 o posterior." }
        guard let bytes = engine.approximateBytes else { return "\(engine.maker) · incluido en macOS" }
        return "\(engine.maker) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var failure: String? {
        if engine == .apple { return appleFailure }
        if case .failed(let message) = managedRow?.state { return message }
        return nil
    }

    private var isInstalled: Bool {
        engine == .apple ? engine.isSupported : managedRow?.state == .installed
    }

    @ViewBuilder
    private var controls: some View {
        if !engine.isSupported {
            EmptyView()
        } else if engine == .apple {
            if isSelected {
                inUse
            } else if isPreparingApple {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Usar", action: select)
                    .bardoSecondaryAction()
                    .help(isAppleReady ? "Transcribir con el reconocimiento de Apple" : "macOS descargará lo necesario para el idioma de este Mac")
            }
        } else if let state = managedRow?.state {
            switch state {
            case .notInstalled:
                Button("Descargar") { action(.install) }
                    .bardoSecondaryAction()
            case .downloading, .preparing:
                Button("Cancelar", role: .cancel) { action(.cancel) }
                    .bardoSecondaryAction()
            case .failed:
                Button("Reintentar") { action(.retry) }
                    .bardoSecondaryAction()
            case .installed:
                HStack(spacing: 8) {
                    if isSelected {
                        inUse
                    } else {
                        Button("Usar", action: select)
                            .bardoSecondaryAction()
                    }
                    moreMenu
                }
            }
        }
    }

    private var inUse: some View {
        Text("En uso")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var moreMenu: some View {
        Menu {
            Button("Mostrar en Finder") { action(.reveal) }
            Divider()
            Button("Eliminar", role: .destructive) { action(.reset) }
                .disabled(isSelected)
        } label: {
            Label("Más opciones de \(engine.title)", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isSelected ? "Para eliminarlo, usa primero otro" : "Más opciones")
    }
}

/// Marks the suggested choice in the accent colour, so it stands out from the rest.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recomendado")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: .capsule)
    }
}
