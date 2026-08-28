import SwiftUI

struct TranscriptionSetupView: View {
    let state: TranscriptionSetupCoordinator.State
    let retry: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 46, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                VStack(spacing: 9) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                VStack(spacing: 12) {
                    if case .failed = state {
                        Button("Try Again", action: retry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 420)

                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(stageLabel)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 500)
                .bardoGlassSurface(cornerRadius: 22)

                VStack(spacing: 5) {
                    Text("About 650 MB is downloaded once.")
                    Text("Transcription stays private and runs on this Mac.")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            }
            .padding(48)
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var title: String {
        switch state {
        case .checking:
            return "Setting Up Bardo"
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Setting Up Bardo"
            case .downloading:
                return "Installing Transcription"
            case .preparingLanguageSupport:
                return "Preparing Language Support"
            case .optimizingForMac:
                return "Optimizing for This Mac"
            }
        case .ready:
            return "Bardo Is Ready"
        case .failed:
            return "Setup Couldn’t Finish"
        }
    }

    private var detail: String {
        switch state {
        case .checking:
            return "Bardo is checking the private on-device transcription engine. This first-time setup only happens once."
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Checking the transcription engine and local model files."
            case .downloading:
                return "Downloading the Large v3 Turbo model so future transcripts can run entirely on-device."
            case .preparingLanguageSupport:
                return "Preparing the tokenizer and multilingual resources used by WhisperKit."
            case .optimizingForMac:
                return "Core ML is loading and specializing the model for this Mac so the first real transcription starts hot."
            }
        case .ready:
            return "The transcription engine is installed, loaded, and ready."
        case .failed(let message):
            return message
        }
    }

    private var stageLabel: String {
        switch state {
        case .checking:
            return "Checking installation…"
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Checking installation…"
            case .downloading:
                return "Downloading transcription model…"
            case .preparingLanguageSupport:
                return "Preparing language support…"
            case .optimizingForMac:
                return "Preparing Core ML…"
            }
        case .ready:
            return "Ready"
        case .failed:
            return "Setup needs attention"
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
                return 0.05 + (0.72 * fraction)
            case .preparingLanguageSupport:
                return 0.78 + (0.08 * fraction)
            case .optimizingForMac:
                return 0.87 + (0.13 * fraction)
            }
        case .ready:
            return 1
        case .failed:
            return 0
        }
    }
}
