import SwiftUI

/// What transcription is doing right now, in words and numbers, so a long job never
/// looks frozen: the step, a bar that moves, the time spent and, while Whisper
/// listens, how much audio is done and roughly how long is left.
struct TranscriptionProgressPanel: View {
    let progress: TranscriptionProgressSnapshot?
    let live: TranscriptionLiveSnapshot?
    let startedAt: Date?
    let stageStartedAt: Date?
    let cancelAction: () -> Void

    var body: some View {
        // Redraw once a second so the elapsed time and estimate keep moving even
        // while the engine reports nothing (loading a model can take minutes).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            panel(now: context.date)
        }
    }

    private func panel(now: Date) -> some View {
        let stage = progress?.stage ?? .preparingModel
        let stageElapsed = stageStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let detail = TranscriptionProgressCopy.detail(
            stage: stage,
            fraction: fraction,
            processedAudio: live?.processedAudioTime ?? 0,
            audioDuration: live?.audioDuration ?? 0,
            stageElapsed: stageElapsed
        )

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label {
                        ThinkingText(text: TranscriptionProgressCopy.thinkingLine(
                            for: stage,
                            fraction: fraction,
                            stageElapsed: stageElapsed
                        ))
                        .font(.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: "waveform")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }

                    Spacer(minLength: 12)

                    Text(statusLine(stage: stage, now: now))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button("Cancelar", role: .cancel, action: cancelAction)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TranscriptionProgressCopy.title(for: stage))
        .accessibilityValue("\(statusLine(stage: stage, now: now)). \(detail)")
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
