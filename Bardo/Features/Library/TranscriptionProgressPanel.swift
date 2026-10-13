import SwiftUI

/// What transcription is doing right now, in words and numbers, so a long job never
/// looks frozen: the step, a bar that moves, the time spent and, while Whisper
/// listens, how much audio is done and roughly how long is left.
struct TranscriptionProgressPanel: View {
    let progress: TranscriptionProgressSnapshot?
    let live: TranscriptionLiveSnapshot?
    let startedAt: Date?
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
            .accessibilityValue("\(state.status). \(state.detail)")
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

            VStack(spacing: 10) {
                progressBar(state)
                    .frame(maxWidth: 320)
                HStack(spacing: 10) {
                    StepDots(current: state.step, total: 4)
                    Text(state.status)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

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
                if let fraction = state.fraction {
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button("Cancelar", role: .cancel, action: cancelAction)
                    .controlSize(.small)
            }

            progressBar(state)
                .controlSize(.small)

            HStack(spacing: 12) {
                Text(state.detail)
                Spacer(minLength: 12)
                if let elapsed = state.elapsed {
                    Text(elapsed)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        let step: Int
        let fraction: Double?
        let line: String
        let detail: String
        let status: String
        let elapsed: String?

        init(panel: TranscriptionProgressPanel, now: Date) {
            stage = panel.progress?.stage ?? .preparingModel
            step = TranscriptionProgressCopy.step(for: stage)
            fraction = panel.fraction
            let stageElapsed = panel.stageStartedAt.map { now.timeIntervalSince($0) } ?? 0
            line = TranscriptionProgressCopy.thinkingLine(for: stage, fraction: fraction, stageElapsed: stageElapsed)
            detail = TranscriptionProgressCopy.detail(
                stage: stage,
                fraction: fraction,
                processedAudio: panel.live?.processedAudioTime ?? 0,
                audioDuration: panel.live?.audioDuration ?? 0,
                stageElapsed: stageElapsed
            )
            elapsed = panel.startedAt.map { TranscriptionProgressCopy.clock(now.timeIntervalSince($0)) }
            status = panel.statusLine(stage: stage, now: now)
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

    private func statusLine(stage: TranscriptionStage, now: Date) -> String {
        var parts = ["Paso \(TranscriptionProgressCopy.step(for: stage)) de 4"]
        if let fraction, stage == .transcribing {
            parts.append("\(Int((fraction * 100).rounded())) %")
        }
        if let startedAt {
            parts.append(TranscriptionProgressCopy.clock(now.timeIntervalSince(startedAt)))
        }
        return parts.joined(separator: " · ")
    }
}

enum TranscriptionProgressCopy {
    static func step(for stage: TranscriptionStage) -> Int {
        switch stage {
        case .preparingModel: 1
        case .loadingModel: 2
        case .transcribing: 3
        case .saving: 4
        }
    }

    /// How long each status line holds before the next one, as in "Thinking states".
    static let thinkingHold: TimeInterval = 2

    /// The plain-language lines a stage cycles through while it runs. They describe
    /// what is really happening; none of them promises progress Bardo cannot measure.
    static func thinkingLines(for stage: TranscriptionStage, fraction: Double?, stageElapsed: TimeInterval) -> [String] {
        switch stage {
        case .preparingModel:
            if fraction != nil {
                return [
                    "Descargando el modelo de voz",
                    "Se guarda en este Mac para usarlo sin conexión"
                ]
            }
            return [
                "Revisando lo necesario para transcribir",
                "Comprobando los archivos del modelo de voz"
            ]
        case .loadingModel:
            // A load that takes long is the one-time optimisation for this Mac.
            if stageElapsed >= 12 {
                return [
                    "Optimizando el modelo para este Mac",
                    "Adaptándolo al chip de tu Mac",
                    "Esto solo pasa la primera vez",
                    "Tus conversaciones no salen de este Mac"
                ]
            }
            return [
                "Cargando el modelo de voz",
                "Preparando el Neural Engine"
            ]
        case .transcribing:
            return [
                "Escuchando la conversación",
                "Reconociendo las palabras",
                "Marcando el momento de cada frase"
            ]
        case .saving:
            return ["Guardando la transcripción"]
        }
    }

    static func thinkingLine(for stage: TranscriptionStage, fraction: Double?, stageElapsed: TimeInterval) -> String {
        let lines = thinkingLines(for: stage, fraction: fraction, stageElapsed: stageElapsed)
        let index = Int(max(0, stageElapsed) / thinkingHold) % lines.count
        return lines[index]
    }

    static func title(for stage: TranscriptionStage) -> String {
        switch stage {
        case .preparingModel: "Preparando la transcripción"
        case .loadingModel: "Cargando el modelo de voz"
        case .transcribing: "Transcribiendo"
        case .saving: "Guardando la transcripción"
        }
    }

    static func detail(
        stage: TranscriptionStage,
        fraction: Double?,
        processedAudio: TimeInterval,
        audioDuration: TimeInterval,
        stageElapsed: TimeInterval
    ) -> String {
        switch stage {
        case .preparingModel:
            if let fraction {
                return "Descargando lo necesario para transcribir en este Mac · \(Int((fraction * 100).rounded())) %"
            }
            return "Comprobando los recursos de transcripción de este Mac."
        case .loadingModel:
            // Core ML compiles the model for this Mac the first time, which takes
            // minutes; say so before anyone wonders whether Bardo is stuck.
            if stageElapsed < 12 {
                return "Bardo está cargando el modelo de voz en este Mac."
            }
            return "La primera vez después de instalar o actualizar Bardo o macOS, el Mac optimiza el modelo de voz y puede tardar unos minutos. Las siguientes transcripciones empiezan casi de inmediato."
        case .transcribing:
            guard audioDuration > 0, processedAudio > 0 else {
                return "Escuchando la conversación. El texto aparecerá aquí a medida que Bardo lo reconozca."
            }
            let heard = "\(LibraryFormatting.duration(processedAudio)) de \(LibraryFormatting.duration(audioDuration))"
            guard let remaining = remainingTime(fraction: fraction, stageElapsed: stageElapsed) else {
                return heard
            }
            return "\(heard) · \(remaining)"
        case .saving:
            return "Guardando la transcripción en tu biblioteca."
        }
    }

    /// A rough estimate once enough audio has been processed to trust the pace.
    static func remainingTime(fraction: Double?, stageElapsed: TimeInterval) -> String? {
        guard let fraction, fraction >= 0.03, fraction < 1, stageElapsed >= 10 else { return nil }
        let remaining = stageElapsed * (1 - fraction) / fraction
        if remaining < 60 {
            return "queda menos de un minuto"
        }
        let minutes = max(1, Int((remaining / 60).rounded()))
        return minutes == 1 ? "queda 1 minuto aproximadamente" : "quedan unos \(minutes) min"
    }

    static func clock(_ interval: TimeInterval) -> String {
        LibraryFormatting.duration(max(0, interval))
    }
}

/// Where the job is among its steps: done steps solid, the current one stretched.
private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .fill(step <= current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .opacity(step == current ? 1 : (step < current ? 0.55 : 1))
                    .frame(width: step == current ? 16 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }
}
