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

    /// One title for the whole download, so the screen doesn't change its headline
    /// at every step; the step itself is named under the progress bar.
    static func title(for stage: Stage) -> String {
        switch stage {
        case .checking, .listening, .settling, .meetingVoices, .welcomingVoices, .namingVoices:
            return "Preparando la transcripción"
        case .ready: return "Bardo está listo"
        case .paused: return "Descarga en pausa"
        case .failed: return "No se pudo completar la descarga"
        }
    }

    static func detail(for stage: Stage) -> String {
        switch stage {
        case .checking, .listening, .settling, .meetingVoices, .welcomingVoices, .namingVoices:
            return "Solo ocurre una vez. Después, Bardo transcribe sin conexión."
        case .ready: return "Ya puedes transcribir sin conexión."
        case .paused: return "Lo descargado se guarda. Reanuda cuando quieras."
        case .failed: return "Comprueba tu conexión a internet e inténtalo de nuevo."
        }
    }

    /// What is happening now, named plainly under the progress bar.
    static func stageLabel(for stage: Stage) -> String {
        switch stage {
        case .checking, .meetingVoices: return "Comprobando…"
        case .listening: return "Reconocimiento de voz"
        case .welcomingVoices: return "Identificación de participantes"
        case .settling, .namingVoices: return "Optimizando para este Mac…"
        case .ready: return "Listo"
        case .paused: return "En pausa"
        case .failed: return "Sin completar"
        }
    }

    static let retryButton = "Intentar de nuevo"
    static let resumeButton = "Reanudar"
    static let resetButton = "Empezar la descarga desde cero"
    static let cancelButton = "Pausar"
    static let useMeanwhileButton = "Usar Bardo mientras tanto"
    static let skipButton = "Continuar sin transcribir"

    static var allVisibleCopy: [String] {
        let stageCopy = Stage.allCases.flatMap { stage in
            [title(for: stage), detail(for: stage), stageLabel(for: stage)]
        }
        return stageCopy + [retryButton, resumeButton, resetButton, cancelButton, useMeanwhileButton, skipButton]
    }
}

struct TranscriptionSetupView: View {
    @ObserveInjection var redraw

    let state: TranscriptionSetupCoordinator.State
    let retry: () -> Void
    let cancel: () -> Void
    let resetAndRetry: () -> Void
    /// Opens the Library while setup continues or stays incomplete.
    let continueWithoutModels: (() -> Void)?

    init(
        state: TranscriptionSetupCoordinator.State,
        retry: @escaping () -> Void,
        cancel: @escaping () -> Void = {},
        resetAndRetry: @escaping () -> Void = {},
        continueWithoutModels: (() -> Void)? = nil
    ) {
        self.state = state
        self.retry = retry
        self.cancel = cancel
        self.resetAndRetry = resetAndRetry
        self.continueWithoutModels = continueWithoutModels
    }

    /// Like the setup assistant: who is asking, what is happening, one line of progress,
    /// and a single clear action, without boxes around any of it.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 18)

            Group {
                if isTerminalState {
                    terminalStateContent
                } else {
                    activeSetupContent
                }
            }
            .padding(.top, 28)

            Spacer(minLength: 32)
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enableInjection()
    }

    /// A thin bar with one line under it: what is happening, and how far along.
    private var activeSetupContent: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                setupProgressIndicator
                HStack(alignment: .firstTextBaseline) {
                    Text(stageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: stageLabel)
                    Spacer(minLength: 12)
                    Text(stepLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if isCancellable {
                VStack(spacing: 10) {
                    if let continueWithoutModels {
                        Button(TranscriptionSetupCopy.useMeanwhileButton, action: continueWithoutModels)
                        .bardoPrimaryAction()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                    Button(TranscriptionSetupCopy.cancelButton, role: .cancel, action: cancel)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var setupProgressIndicator: some View {
        if let fraction = measuredProgressFraction {
            ProgressView(value: fraction)
                .animation(.easeOut(duration: 0.2), value: fraction)
                .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel(stageLabel)
        }
    }

    /// One main action, the alternative beside it, and starting over as a quiet link.
    private var terminalStateContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if let continueWithoutModels {
                    Button(TranscriptionSetupCopy.skipButton, action: continueWithoutModels)
                        .bardoSecondaryAction()
                }
                Button(isPaused ? TranscriptionSetupCopy.resumeButton : TranscriptionSetupCopy.retryButton, action: retry)
                    .bardoPrimaryAction()
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

            if let failureReason {
                Text(failureReason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Button(TranscriptionSetupCopy.resetButton, action: resetAndRetry)
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var isPaused: Bool {
        switch state {
        case .cancelled, .needsInstall: true
        default: false
        }
    }

    /// What went wrong, when it says more than the screen already does.
    private var failureReason: String? {
        guard case .failed(let message) = state, !message.isEmpty else { return nil }
        let alreadySaid = [
            String(localized: "Bardo could not connect to the internet. Check your connection and try again.")
        ]
        return alreadySaid.contains(message) ? nil : message
    }

    private var isTerminalState: Bool {
        switch state {
        case .cancelled, .failed, .needsInstall:
            return true
        case .checking, .installing, .installingSpeakers, .ready:
            return false
        }
    }

    private var isCancellable: Bool {
        switch state {
        case .checking, .installing, .installingSpeakers:
            return true
        case .ready, .cancelled, .failed, .needsInstall:
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
        case .cancelled, .needsInstall:
            return .paused
        case .failed:
            return .failed
        }
    }

    private var measuredProgressFraction: Double? {
        switch state {
        case .installing(let progress) where progress.stage == .downloading:
            return min(1, max(0, progress.fractionCompleted))
        case .installingSpeakers(let progress) where progress.stage == .downloading:
            return min(1, max(0, progress.fractionCompleted))
        case .checking, .installing, .installingSpeakers, .ready, .cancelled, .failed, .needsInstall:
            return nil
        }
    }

    /// How far along: which of the two downloads, and its share when it is measured.
    private var stepLabel: String {
        let step: Int
        switch state {
        case .installing: step = 1
        case .installingSpeakers: step = 2
        case .checking, .ready, .cancelled, .failed, .needsInstall: return ""
        }
        guard let fraction = measuredProgressFraction else { return "\(step) de 2" }
        return "\(step) de 2 · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }
}
