import SwiftUI

enum TranscriptionSetupCopy {
    enum Stage: CaseIterable, Hashable, Sendable {
        case checking
        case listening
        case settling
        case meetingVoices
        case welcomingVoices
        case namingVoices
        case ready
        case paused
        case failed
    }

    static func title(for stage: Stage) -> String {
        switch stage {
        case .checking: return "Preparando Bardo"
        case .listening: return "Bardo está aprendiendo a escuchar"
        case .settling: return "Bardo está terminando de prepararse"
        case .meetingVoices: return "Preparando la identificación de participantes"
        case .welcomingVoices: return "Bardo está organizando las voces"
        case .namingVoices: return "Bardo está ordenando la conversación"
        case .ready: return "Bardo está listo"
        case .paused: return "Puedes continuar después"
        case .failed: return "Algo salió mal"
        }
    }

    static func detail(for stage: Stage) -> String {
        switch stage {
        case .checking: return "Estamos revisando que todo esté listo."
        case .listening: return "Estamos preparando el reconocimiento de voz."
        case .settling: return "Estamos terminando la preparación."
        case .meetingVoices: return "Estamos preparando la identificación de participantes."
        case .welcomingVoices: return "Cada voz tendrá su propio espacio."
        case .namingVoices: return "Estamos ordenando quién dijo cada cosa."
        case .ready: return "Todo quedará procesado de forma privada en este Mac."
        case .paused: return "Tu progreso está guardado y podrás retomarlo después."
        case .failed: return "No pudimos terminar. Inténtalo de nuevo cuando quieras."
        }
    }

    static func stageLabel(for stage: Stage) -> String {
        switch stage {
        case .checking: return "Revisando…"
        case .listening: return "Preparando el reconocimiento de voz…"
        case .settling: return "Terminando la preparación…"
        case .meetingVoices: return "Preparando participantes…"
        case .welcomingVoices: return "Organizando las voces…"
        case .namingVoices: return "Ordenando la conversación…"
        case .ready: return "Listo"
        case .paused: return "En pausa"
        case .failed: return "Necesita otro intento"
        }
    }

    static func messages(for stage: Stage) -> [String] {
        switch stage {
        case .checking:
            return [
                "Comprobando que todo esté en su sitio.",
                "Buscando lo necesario para empezar.",
                "Dejando listo lo importante para después."
            ]
        case .listening:
            return [
                "Preparando el reconocimiento de voz.",
                "Dejando todo listo para escuchar.",
                "Bardo está aprendiendo a reconocer voces.",
                "La parte silenciosa está avanzando.",
                "Ya falta menos para empezar."
            ]
        case .settling:
            return [
                "Terminando de preparar todo.",
                "Bardo está ajustando los últimos detalles.",
                "Un momento más y estaremos listos.",
                "Ya casi terminamos.",
                "Todo está tomando su lugar."
            ]
        case .meetingVoices:
            return [
                "Preparando un lugar para cada participante.",
                "Nos aseguramos de incluir todas las voces.",
                "Bardo está identificando quién participa."
            ]
        case .welcomingVoices:
            return [
                "Organizando cada voz de la conversación.",
                "Dando a cada participante su propio espacio.",
                "Todo se procesa de forma privada en este Mac."
            ]
        case .namingVoices:
            return [
                "Ordenando quién dijo cada cosa.",
                "Colocando cada voz en el lugar correcto.",
                "Terminando de organizar la conversación."
            ]
        case .ready:
            return ["Listo cuando tú quieras.", "Todo está preparado.", "Bardo ya puede empezar."]
        case .paused:
            return ["Tu progreso está guardado.", "Podrás continuar cuando quieras.", "Bardo estará aquí."]
        case .failed:
            return ["No se perdió nada.", "Puedes intentarlo otra vez.", "Volveremos a empezar desde aquí."]
        }
    }

    static func progressLabel(for stage: Stage, stageFraction: Double, overallFraction: Double) -> String {
        let stagePercent = percentage(stageFraction)
        let overallPercent = percentage(overallFraction)

        switch stage {
        case .ready: return "Todo listo"
        case .paused: return "En pausa"
        case .failed: return "Esperando otro intento"
        default: return "Esta etapa: \(stagePercent)%  ·  Total: \(overallPercent)%"
        }
    }

    static let retryButton = "Intentar de nuevo"
    static let resetButton = "Empezar de nuevo"
    static let cancelButton = "Pausar"
    static let footer = "Esto solo ocurre una vez. Después, Bardo estará listo para ti."

    static var allVisibleCopy: [String] {
        let stageCopy = Stage.allCases.flatMap { stage in
            [title(for: stage), detail(for: stage), stageLabel(for: stage)] + messages(for: stage)
        }
        return stageCopy + [retryButton, resetButton, cancelButton, footer]
    }

    private static func percentage(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction.isFinite ? fraction : 0)) * 100).rounded())
    }
}

struct TranscriptionSetupView: View {
    @ObserveInjection var redraw
    private enum Layout {
        static let titleHeight: CGFloat = 40
        static let detailHeight: CGFloat = 24
        static let progressLabelHeight: CGFloat = 18
        static let stageLabelHeight: CGFloat = 22
        static let asideHeight: CGFloat = 22
        static let footerHeight: CGFloat = 20
    }

    let state: TranscriptionSetupCoordinator.State
    let retry: () -> Void
    let cancel: () -> Void
    let resetAndRetry: () -> Void

    init(
        state: TranscriptionSetupCoordinator.State,
        retry: @escaping () -> Void,
        cancel: @escaping () -> Void = {},
        resetAndRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.retry = retry
        self.cancel = cancel
        self.resetAndRetry = resetAndRetry
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var messageIndex = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 42, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: 520, minHeight: Layout.titleHeight, maxHeight: Layout.titleHeight)

                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: 520, minHeight: Layout.detailHeight, maxHeight: Layout.detailHeight)
                }

                VStack(spacing: 14) {
                    if case .failed = state {
                        setupActions
                    } else if case .cancelled = state {
                        setupActions
                    } else {
                        HStack(spacing: 12) {
                            ProgressView(value: progressValue)
                                .progressViewStyle(.linear)

                            Text(percentText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }

                        Text(progressLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 410, minHeight: Layout.progressLabelHeight, maxHeight: Layout.progressLabelHeight)

                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(stageLabel)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(height: Layout.stageLabelHeight)
                        }

                        if isCancellable {
                            Button(role: .cancel, action: cancel) {
                                Text(TranscriptionSetupCopy.cancelButton)
                                    .lineLimit(1)
                            }
                        }

                        Text(currentAside)
                            .id(currentAside)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .frame(maxWidth: 410, minHeight: Layout.asideHeight, maxHeight: Layout.asideHeight)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(width: 480)
                .bardoGlassSurface(cornerRadius: BardoCornerRadius.setup)

                Text(TranscriptionSetupCopy.footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: 620, minHeight: Layout.footerHeight, maxHeight: Layout.footerHeight)
            }
            .padding(48)
        }
        .frame(minWidth: 680, minHeight: 500)
        .task(id: copyStage) {
            messageIndex = 0
            guard !reduceMotion else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_800_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.24)) {
                    messageIndex = (messageIndex + 1) % messages.count
                }
            }
        }
        .enableInjection()
    }

    @ViewBuilder
    private var setupActions: some View {
        HStack(spacing: 12) {
            Button(action: retry) {
                Text(TranscriptionSetupCopy.retryButton)
                    .lineLimit(1)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Button(action: resetAndRetry) {
                Text(TranscriptionSetupCopy.resetButton)
                    .lineLimit(1)
            }
                .controlSize(.large)
        }
    }

    private var isCancellable: Bool {
        switch state {
        case .checking, .installing, .installingSpeakers:
            return true
        case .ready, .cancelled, .failed:
            return false
        }
    }

    private var title: String {
        TranscriptionSetupCopy.title(for: copyStage)
    }

    private var detail: String {
        TranscriptionSetupCopy.detail(for: copyStage)
    }

    private var stageLabel: String {
        TranscriptionSetupCopy.stageLabel(for: copyStage)
    }

    private var copyStage: TranscriptionSetupCopy.Stage {
        switch state {
        case .checking:
            return .checking
        case .installing(let progress):
            switch progress.stage {
            case .checking: return .checking
            case .downloading: return .listening
            case .optimizingForMac: return .settling
            }
        case .installingSpeakers(let progress):
            switch progress.stage {
            case .checking: return .meetingVoices
            case .downloading: return .welcomingVoices
            case .optimizingForMac: return .namingVoices
            }
        case .ready:
            return .ready
        case .cancelled:
            return .paused
        case .failed:
            return .failed
        }
    }

    private var messages: [String] {
        TranscriptionSetupCopy.messages(for: copyStage)
    }

    private var currentAside: String {
        let available = messages
        guard !available.isEmpty else { return "" }
        return available[min(messageIndex, available.count - 1)]
    }

    private var progressValue: Double {
        switch state {
        case .checking:
            return 0.02
        case .installing(let progress):
            let fraction = min(1, max(0, progress.fractionCompleted))
            switch progress.stage {
            case .checking:
                return 0.03
            case .downloading:
                return 0.03 + (0.42 * fraction)
            case .optimizingForMac:
                return 0.50 + (0.40 * fraction)
            }
        case .installingSpeakers(let progress):
            let fraction = min(1, max(0, progress.fractionCompleted))
            switch progress.stage {
            case .checking:
                return 0.90 + (0.03 * fraction)
            case .downloading:
                return 0.90 + (0.03 * fraction)
            case .optimizingForMac:
                return 0.93 + (0.07 * fraction)
            }
        case .ready:
            return 1
        case .cancelled:
            return 0
        case .failed:
            return 0
        }
    }

    private var percentText: String {
        "\(Int((progressValue * 100).rounded()))%"
    }

    private var progressLabel: String {
        TranscriptionSetupCopy.progressLabel(
            for: copyStage,
            stageFraction: stageProgressValue,
            overallFraction: progressValue
        )
    }

    private var stageProgressValue: Double {
        switch state {
        case .checking, .cancelled, .failed:
            return 0
        case .ready:
            return 1
        case .installing(let progress):
            return progress.fractionCompleted
        case .installingSpeakers(let progress):
            return progress.fractionCompleted
        }
    }
}
