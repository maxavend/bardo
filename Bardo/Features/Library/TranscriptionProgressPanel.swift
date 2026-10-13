import SwiftUI

/// What transcription is doing right now, in words and numbers, so a long job never
/// looks frozen: the step, a bar that moves, the time spent and, while Whisper
/// listens, how much audio is done and roughly how long is left.
struct TranscriptionProgressPanel: View {
    let progress: TranscriptionProgressSnapshot?
    let live: TranscriptionLiveSnapshot?
    let stageStartedAt: Date?
    /// Text is already streaming in: step aside into a slim header so the words lead.
    var isCompact = false
    let cancelAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Redraw once a second so the elapsed time and estimate keep moving even
        // while the engine reports nothing (loading a model can take minutes).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = State(panel: self, now: context.date)
            Group {
                if isCompact {
                    compact(state)
                } else {
                    hero(state)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(TranscriptionProgressCopy.title(for: state.stage))
            .accessibilityValue([state.line, state.figures, state.detail].compactMap { $0 }.joined(separator: ". "))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isCompact)
    }

    // MARK: Waiting for the first words

    /// Nothing is on screen yet, which is when a job looks frozen: give the moment
    /// the whole space, with something that visibly moves.
    private func hero(_ state: State) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                ThinkingText(text: state.line, alignment: .center)
                    .font(.title3.weight(.semibold))
                Text(state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            progressBar(state)
                .frame(maxWidth: 320)

            Button("Cancelar", role: .cancel, action: cancelAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: While text streams in

    private func compact(_ state: State) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                ThinkingText(text: state.line)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 12)
                if let figures = state.figures {
                    Text(figures)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Button("Cancelar", role: .cancel, action: cancelAction)
                    .controlSize(.small)
            }

            progressBar(state)
                .controlSize(.small)
        }
        .padding(.bottom, 4)
    }

    /// Only real, measurable progress gets a bar; while a step cannot be measured the
    /// moving icon, the shimmering line and the step dots carry the activity.
    @ViewBuilder
    private func progressBar(_ state: State) -> some View {
        if let fraction = state.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
    }

    /// Everything the panel shows at one moment.
    private struct State {
        let stage: TranscriptionStage
        let fraction: Double?
        let line: String
        let detail: String
        /// The measurable part, shown on the right: audio heard and percentage.
        let figures: String?

        init(panel: TranscriptionProgressPanel, now: Date) {
            stage = panel.progress?.stage ?? .preparingModel
            fraction = panel.fraction
            let context = TranscriptionProgressCopy.Context(
                stage: stage,
                fraction: fraction,
                processedAudio: panel.live?.processedAudioTime ?? 0,
                audioDuration: panel.live?.audioDuration ?? 0,
                stageElapsed: panel.stageStartedAt.map { now.timeIntervalSince($0) } ?? 0
            )
            line = TranscriptionProgressCopy.thinkingLine(for: context)
            detail = TranscriptionProgressCopy.detail(for: context)
            figures = TranscriptionProgressCopy.figures(for: context)
        }
    }

    /// Determinate only when the engine reports real progress.
    private var fraction: Double? {
        guard let progress else { return nil }
        switch progress.stage {
        case .preparingModel:
            return progress.fractionCompleted > 0 && progress.fractionCompleted < 1
                ? progress.fractionCompleted
                : nil
        case .transcribing:
            let value = max(progress.fractionCompleted, live?.fractionCompleted ?? 0)
            return min(1, max(0, value))
        case .loadingModel, .saving:
            return nil
        }
    }
}

enum TranscriptionProgressCopy {
    /// Everything the copy can draw on at one moment.
    struct Context {
        var stage: TranscriptionStage
        var fraction: Double?
        var processedAudio: TimeInterval = 0
        var audioDuration: TimeInterval = 0
        var stageElapsed: TimeInterval = 0
    }

    /// How long each status line rests before the next one: calm, never hurried.
    static let thinkingHold: TimeInterval = 4.5

    /// Two quiet lines per stage that say what Bardo is doing. Numbers live on the
    /// right (see `figures`), so these stay short and calm.
    static func thinkingLines(for context: Context) -> [String] {
        switch context.stage {
        case .preparingModel:
            context.fraction != nil
                ? ["Descargando el modelo de voz", "Solo se hace una vez"]
                : ["Preparando todo", "Revisando el modelo de voz"]
        case .loadingModel:
            // A load that takes long is the one-time optimisation for this Mac.
            context.stageElapsed >= 12
                ? ["Optimizando el modelo para tu Mac", "Solo pasa la primera vez"]
                : ["Cargando el modelo de voz", "Preparando el Neural Engine"]
        case .transcribing:
            ["Escuchando la conversación", "Escribiendo lo que se dice"]
        case .saving:
            ["Guardando la transcripción"]
        }
    }

    static func thinkingLine(for context: Context) -> String {
        let lines = thinkingLines(for: context)
        let index = Int(max(0, context.stageElapsed) / thinkingHold) % lines.count
        return lines[index]
    }

    /// What can be measured right now: audio heard and percentage while
    /// transcribing, the percentage while downloading; nothing otherwise.
    static func figures(for context: Context) -> String? {
        guard let fraction = context.fraction else { return nil }
        let percent = "\(Int((fraction * 100).rounded())) %"
        guard context.stage == .transcribing, context.audioDuration > 0, context.processedAudio > 0 else {
            return percent
        }
        return "\(clock(context.processedAudio)) de \(clock(context.audioDuration)) · \(percent)"
    }

    /// The accessibility name of the panel; it does not change while a stage runs.
    static func title(for stage: TranscriptionStage) -> String {
        switch stage {
        case .preparingModel: "Preparando la transcripción"
        case .loadingModel: "Cargando el modelo de voz"
        case .transcribing: "Transcribiendo"
        case .saving: "Guardando la transcripción"
        }
    }

    /// The explanation under the status line while nothing is on screen yet.
    static func detail(for context: Context) -> String {
        switch context.stage {
        case .preparingModel:
            context.fraction != nil
                ? "Bardo descarga el modelo de voz una sola vez; después transcribe sin conexión."
                : "Bardo comprueba que el modelo de voz esté listo en este Mac."
        case .loadingModel:
            // Core ML compiles the model for this Mac the first time, which takes
            // minutes; say so before anyone wonders whether Bardo is stuck.
            context.stageElapsed < 12
                ? "Bardo está cargando el modelo de voz en este Mac."
                : "La primera vez después de instalar o actualizar Bardo o macOS, el Mac optimiza el modelo de voz. Las siguientes transcripciones empiezan casi de inmediato."
        case .transcribing:
            "El texto aparecerá aquí a medida que Bardo lo reconozca."
        case .saving:
            "Casi listo: la transcripción se está guardando en tu biblioteca."
        }
    }

    static func clock(_ interval: TimeInterval) -> String {
        LibraryFormatting.duration(max(0, interval))
    }
}
