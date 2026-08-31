import SwiftUI

struct TranscriptionSetupView: View {
    let state: TranscriptionSetupCoordinator.State
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 7) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 38, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(titleKey, tableName: nil)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(detailKey, tableName: nil)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            VStack(spacing: 0) {
                SetupComponentRow(
                    title: "Transcription",
                    systemImage: "waveform",
                    state: transcriptionComponentState
                )

                Divider()
                    .padding(.leading, 44)

                SetupComponentRow(
                    title: "Speaker Detection",
                    systemImage: "person.2",
                    state: speakerComponentState
                )
            }
            .frame(width: 470)
            .padding(.horizontal, 16)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }

            if case .failed = state {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            Text("Transcription and speaker detection run locally on this Mac once setup is complete.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(44)
        .frame(minWidth: 680, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleKey: LocalizedStringKey {
        switch state {
        case .ready: "Bardo Is Ready"
        case .failed: "Setup Couldn’t Finish"
        default: "Preparing Bardo"
        }
    }

    private var detailKey: LocalizedStringKey {
        switch state {
        case .checking:
            "Checking the local models Bardo needs."
        case .installing:
            "Preparing private, on-device transcription."
        case .installingSpeakers:
            "Preparing local speaker detection."
        case .ready:
            "Everything Bardo needs is installed and ready."
        case .failed(let message):
            LocalizedStringKey(message)
        }
    }

    private var transcriptionComponentState: SetupComponentState {
        switch state {
        case .checking:
            .working("Checking…", nil)
        case .installing(let progress):
            .working(transcriptionStage(progress.stage), progress.fractionCompleted)
        case .installingSpeakers, .ready:
            .complete
        case .failed:
            .failed
        }
    }

    private var speakerComponentState: SetupComponentState {
        switch state {
        case .checking, .installing:
            .waiting
        case .installingSpeakers(let progress):
            .working(speakerStage(progress.stage), progress.fractionCompleted)
        case .ready:
            .complete
        case .failed:
            .failed
        }
    }

    private func transcriptionStage(_ stage: TranscriptionSetupStage) -> LocalizedStringKey {
        switch stage {
        case .checking: "Checking…"
        case .downloading: "Installing…"
        case .preparingLanguageSupport: "Preparing languages…"
        case .optimizingForMac: "Optimizing for this Mac…"
        }
    }

    private func speakerStage(_ stage: DiarizationSetupStage) -> LocalizedStringKey {
        switch stage {
        case .downloading: "Installing…"
        case .optimizingForMac: "Optimizing for this Mac…"
        }
    }
}

private enum SetupComponentState {
    case waiting
    case working(LocalizedStringKey, Double?)
    case complete
    case failed
}

private struct SetupComponentRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let state: SetupComponentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.body.weight(.medium))

            Spacer(minLength: 12)

            statusView
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .waiting:
            Text("Waiting")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .working(let label, let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .frame(width: 76)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .complete:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
