import SwiftUI

/// Shows transcription setup that is still running, paused or failed while the Library
/// is already usable. Recording, importing and playback never wait for it.
struct SetupStatusBanner: View {
    @ObservedObject var setup: TranscriptionSetupCoordinator

    static func isNeeded(for state: TranscriptionSetupCoordinator.State) -> Bool {
        switch state {
        case .installing, .installingSpeakers, .cancelled, .failed, .needsInstall:
            return true
        case .checking, .ready:
            return false
        }
    }

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                leadingIndicator

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(detail)
                }

                Spacer(minLength: 16)

                actionButton
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 720)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch setup.state {
        case .installing(let progress):
            progressIndicator(progress.stage == .downloading ? progress.fractionCompleted : nil)
        case .installingSpeakers(let progress):
            progressIndicator(progress.stage == .downloading ? progress.fractionCompleted : nil)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .cancelled, .needsInstall, .checking, .ready:
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func progressIndicator(_ fraction: Double?) -> some View {
        Group {
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch setup.state {
        case .installing, .installingSpeakers:
            Button("Pausar", role: .cancel) { setup.cancelPreparation() }
        case .cancelled:
            Button("Continuar") { setup.retry() }
        case .failed:
            Button("Reintentar") { setup.retry() }
        case .needsInstall:
            Button("Descargar") { setup.retry() }
        case .checking, .ready:
            EmptyView()
        }
    }

    private var title: String {
        switch setup.state {
        case .installing:
            return "Preparando la transcripción"
        case .installingSpeakers:
            return "Preparando la identificación de hablantes"
        case .cancelled:
            return "La preparación de la transcripción está en pausa"
        case .failed:
            return "No pudimos preparar la transcripción"
        case .needsInstall:
            return "Faltan los recursos para transcribir"
        case .checking, .ready:
            return ""
        }
    }

    private var detail: String {
        switch setup.state {
        case .installing(let progress):
            return progress.stage == .downloading
                ? "Descargando · \(percentage(progress.fractionCompleted)). Puedes grabar e importar audio mientras tanto."
                : "Dejando todo listo en este Mac. Puedes grabar e importar audio mientras tanto."
        case .installingSpeakers(let progress):
            return progress.stage == .downloading
                ? "Descargando · \(percentage(progress.fractionCompleted)). Puedes seguir usando Bardo."
                : "Dejando todo listo en este Mac. Puedes seguir usando Bardo."
        case .cancelled:
            return "Lo descargado se conserva. Continúa cuando tengas conexión."
        case .failed(let message):
            return message
        case .needsInstall:
            return "Descárgalos para transcribir e identificar hablantes de forma privada en este Mac."
        case .checking, .ready:
            return ""
        }
    }

    private func percentage(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded())) %"
    }
}
