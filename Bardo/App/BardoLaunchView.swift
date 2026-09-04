import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()
    @AppStorage("Bardo.WelcomeCompleted.v1") private var hasCompletedWelcome = false

    var body: some View {
        Group {
            if setup.isReady {
                RootView(warmTranscriptionForRecording: setup.warmForRecording)
            } else if !hasCompletedWelcome {
                BardoWelcomeView {
                    hasCompletedWelcome = true
                    setup.startPreparation()
                }
            } else {
                TranscriptionSetupView(
                    state: setup.state,
                    retry: setup.retry,
                    cancel: setup.cancelPreparation,
                    resetAndRetry: setup.resetAndRetry
                )
            }
        }
        .task {
            if hasCompletedWelcome {
                setup.startPreparation()
            }
        }
    }
}

private struct BardoWelcomeView: View {
    let continueAction: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 32)

            GroupBox {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(localized: "Welcome to"))
                            .foregroundStyle(Color.accentColor)
                        Text("Bardo")
                    }
                    .font(.title2.weight(.bold))

                    VStack(alignment: .leading, spacing: 18) {
                        WelcomeFeatureRow(
                            systemImage: "waveform.and.mic",
                            title: String(localized: "Transcribe conversations"),
                            detail: String(localized: "Turn recordings into readable text locally on your Mac.")
                        )

                        WelcomeFeatureRow(
                            systemImage: "person.2.wave.2",
                            title: String(localized: "Identify participants"),
                            detail: String(localized: "Organize conversations by speaker so each voice has its own place.")
                        )

                        WelcomeFeatureRow(
                            systemImage: "list.bullet.clipboard",
                            title: String(localized: "Create meeting minutes"),
                            detail: String(localized: "Summarize decisions, tasks, and next steps on-device.")
                        )
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34)
                            .accessibilityHidden(true)

                        Text(String(localized: "Bardo processes your recordings locally on this Mac. Audio, transcripts, and minutes stay on your device."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()

                        Button(String(localized: "Continue"), action: continueAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: 500)

            Spacer(minLength: 32)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
