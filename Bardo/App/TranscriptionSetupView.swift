import SwiftUI

struct TranscriptionSetupView: View {
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

                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
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

                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(stageLabel)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        if isCancellable {
                            Button("Cancel", role: .cancel, action: cancel)
                        }

                        Text(currentAside)
                            .id(currentAside)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 410, minHeight: 34)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(width: 480)
                .bardoGlassSurface(cornerRadius: BardoCornerRadius.setup)

                VStack(spacing: 5) {
                    Text("This setup only happens once.")
                    Text("After it finishes, transcription and speaker detection run privately on this Mac.")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            }
            .padding(48)
        }
        .frame(minWidth: 680, minHeight: 500)
        .task(id: messageGroup) {
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
    }

    @ViewBuilder
    private var setupActions: some View {
        HStack(spacing: 12) {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Button("Reset & Download Again", action: resetAndRetry)
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
        switch state {
        case .checking:
            return "Getting Bardo Ready"
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Getting Bardo Ready"
            case .downloading:
                return "Installing Transcription"
            case .preparingLanguageSupport:
                return "Preparing Languages"
            case .optimizingForMac:
                return "Optimizing for This Mac"
            }
        case .installingSpeakers(let progress):
            switch progress.stage {
            case .downloading:
                return "Learning Who Said What"
            case .optimizingForMac:
                return "Finishing the Voice Setup"
            }
        case .ready:
            return "Bardo Is Ready"
        case .cancelled:
            return "Setup Paused"
        case .failed:
            return "Setup Couldn’t Finish"
        }
    }

    private var detail: String {
        switch state {
        case .checking:
            return "Checking the local speech models before the library opens."
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Checking what’s already here so Bardo only installs what it needs."
            case .downloading:
                return "Downloading the local transcription engine. Your audio won’t need to leave this Mac."
            case .preparingLanguageSupport:
                return "Preparing multilingual transcription so Bardo can keep up when the conversation switches gears."
            case .optimizingForMac:
                return "Making the transcription engine comfortable on this Mac before you ask it to work."
            }
        case .installingSpeakers(let progress):
            switch progress.stage {
            case .downloading:
                return "Adding local speaker detection now, so there’s no surprise download later."
            case .optimizingForMac:
                return "Warming up the voice models so speaker-aware transcripts are ready too."
            }
        case .ready:
            return "Everything is installed, warmed up, and ready to stay local."
        case .cancelled:
            return "Setup was cancelled. Nothing was deleted; you can continue or reset the private models."
        case .failed(let message):
            return message
        }
    }

    private var stageLabel: String {
        switch state {
        case .checking:
            return "Checking the setup…"
        case .installing(let progress):
            switch progress.stage {
            case .checking:
                return "Checking the setup…"
            case .downloading:
                return "Installing transcription…"
            case .preparingLanguageSupport:
                return "Preparing languages…"
            case .optimizingForMac:
                return "Optimizing transcription…"
            }
        case .installingSpeakers(let progress):
            switch progress.stage {
            case .downloading:
                return "Installing speaker detection…"
            case .optimizingForMac:
                return "Optimizing speaker detection…"
            }
        case .ready:
            return "Ready"
        case .cancelled:
            return "Setup cancelled"
        case .failed:
            return "Setup needs attention"
        }
    }

    private var messageGroup: MessageGroup {
        switch state {
        case .checking:
            return .checking
        case .installing(let progress):
            switch progress.stage {
            case .checking: return .checking
            case .downloading: return .transcriptionDownload
            case .preparingLanguageSupport: return .languages
            case .optimizingForMac: return .transcriptionOptimize
            }
        case .installingSpeakers(let progress):
            switch progress.stage {
            case .downloading: return .speakerDownload
            case .optimizingForMac: return .speakerOptimize
            }
        case .ready:
            return .ready
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }

    private var messages: [String] {
        switch messageGroup {
        case .checking:
            return [
                "Checking the toolbox before we make any noise.",
                "Looking for anything we can reuse. Waste not, wait not.",
                "Doing the boring part now so you don’t have to later."
            ]
        case .transcriptionDownload:
            return [
                "Bringing Bardo its ears. They’re a little chunky.",
                "One download now. A lot less staring at spinners later.",
                "Teaching the app to listen without phoning home.",
                "The good news: this is the slowest part, and it only happens once."
            ]
        case .languages:
            return [
                "Sorting out words, accents, and the occasional dramatic pause.",
                "Making room for more than one language. Ambitious, but fair.",
                "Putting the tiny dictionary shelves where they belong."
            ]
        case .transcriptionOptimize:
            return [
                "Introducing the transcription engine to this Mac. They’re getting along.",
                "Letting Core ML pick the comfy seats.",
                "Warming up the fast path. Future-you says thanks.",
                "Almost there. The silicon is stretching."
            ]
        case .speakerDownload:
            return [
                "Adding the part that knows who said what.",
                "Handing everyone invisible name tags.",
                "No cloud meeting bot has been invited to this conversation."
            ]
        case .speakerOptimize:
            return [
                "Teaching Bardo to tell voices apart without starting arguments.",
                "Putting the speaker detector on its best behavior.",
                "Final warm-up. Then you can transcribe to your heart’s content."
            ]
        case .ready:
            return ["Ready when you are."]
        case .cancelled:
            return ["Your models are still safe. Resume whenever you’re ready."]
        case .failed:
            return ["Nothing was thrown away. Try again and Bardo will pick up where it can."]
        }
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
                return 0.05 + (0.60 * fraction)
            case .preparingLanguageSupport:
                return 0.66 + (0.06 * fraction)
            case .optimizingForMac:
                return 0.73 + (0.10 * fraction)
            }
        case .installingSpeakers(let progress):
            let fraction = min(1, max(0, progress.fractionCompleted))
            switch progress.stage {
            case .downloading:
                return 0.84 + (0.10 * fraction)
            case .optimizingForMac:
                return 0.95 + (0.05 * fraction)
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

    private enum MessageGroup: Hashable {
        case checking
        case transcriptionDownload
        case languages
        case transcriptionOptimize
        case speakerDownload
        case speakerOptimize
        case ready
        case cancelled
        case failed
    }
}
