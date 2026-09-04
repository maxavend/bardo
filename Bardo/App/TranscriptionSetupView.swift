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
        case .listening: return "Preparando Bardo"
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
        case .listening: return "Estamos preparando todo para que puedas empezar."
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

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            Image(systemName: "waveform.badge.mic")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    if isTerminalState {
                        terminalStateContent
                    } else {
                        activeSetupContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520)

            Text(TranscriptionSetupCopy.footer)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Spacer(minLength: 24)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enableInjection()
    }

    private var activeSetupContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progressValue)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label {
                    Text(stageLabel)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 12)

                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(progressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isCancellable {
                HStack {
                    Spacer()
                    Button(TranscriptionSetupCopy.cancelButton, role: .cancel, action: cancel)
                }
            }
        }
    }

    private var terminalStateContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(stageLabel, systemImage: terminalStateSymbol)
                .font(.headline)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            setupActions
        }
    }

    private var setupActions: some View {
        HStack(spacing: 10) {
            Button(TranscriptionSetupCopy.retryButton, action: retry)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            Button(TranscriptionSetupCopy.resetButton, action: resetAndRetry)

            Spacer()
        }
    }

    private var isTerminalState: Bool {
        switch state {
        case .cancelled, .failed:
            return true
        case .checking, .installing, .installingSpeakers, .ready:
            return false
        }
    }

    private var terminalStateSymbol: String {
        switch state {
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "pause.circle"
        default:
            return "checkmark.circle"
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
        case .cancelled, .failed:
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