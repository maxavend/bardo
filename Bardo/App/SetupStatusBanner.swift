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
            Button(String(localized: "Pause"), role: .cancel) { setup.cancelPreparation() }
        case .cancelled:
            Button(String(localized: "Continue")) { setup.retry() }
        case .failed:
            Button(String(localized: "Retry")) { setup.retry() }
        case .needsInstall:
            Button(String(localized: "Download")) { setup.retry() }
        case .checking, .ready:
            EmptyView()
        }
    }

    private var title: String {
        switch setup.state {
        case .installing:
            return String(localized: "Preparing transcription")
        case .installingSpeakers:
            return String(localized: "Preparing speaker identification")
        case .cancelled:
            return String(localized: "Transcription setup is paused")
        case .failed:
            return String(localized: "Transcription setup could not finish")
        case .needsInstall:
            return String(localized: "Transcription resources are missing")
        case .checking, .ready:
            return ""
        }
    }

    private var detail: String {
        switch setup.state {
        case .installing(let progress):
            return progress.stage == .downloading
                ? String(localized: "Downloading · \(percentage(progress.fractionCompleted)). You can record and import audio meanwhile.")
                : String(localized: "Getting everything ready on this Mac. You can record and import audio meanwhile.")
        case .installingSpeakers(let progress):
            return progress.stage == .downloading
                ? String(localized: "Downloading · \(percentage(progress.fractionCompleted)). You can keep using Bardo.")
                : String(localized: "Getting everything ready on this Mac. You can keep using Bardo.")
        case .cancelled:
            return String(localized: "What was downloaded is kept. Continue when you are online.")
        case .failed(let message):
            return message
        case .needsInstall:
            return String(localized: "Download them to transcribe and identify speakers privately on this Mac.")
        case .checking, .ready:
            return ""
        }
    }

    private func percentage(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded())) %"
    }
}
