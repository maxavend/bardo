import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()
    @AppStorage("Bardo.WelcomeCompleted.v1") private var hasCompletedWelcome = false

    var body: some View {
        #if DEBUG
        if DesignReview.showsWelcome {
            BardoWelcomeView {}
        } else {
            launchContent
        }
        #else
        launchContent
        #endif
    }

    private var launchContent: some View {
        Group {
            // Once unlocked, the Library never goes away again during a session: missing
            // or failing models only affect transcription, shown in a banner.
            if setup.isLibraryUnlocked {
                RootView(
                    warmTranscriptionForRecording: setup.warmForRecording,
                    setupBanner: SetupStatusBanner.isNeeded(for: setup.state)
                        ? AnyView(SetupStatusBanner(setup: setup))
                        : nil
                )
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
                    resetAndRetry: setup.resetAndRetry,
                    continueWithoutModels: setup.unlockLibrary
                )
            }
        }
        .task {
            if hasCompletedWelcome || setup.isLibraryUnlocked {
                setup.startPreparation()
            }
        }
    }
}

private struct BardoWelcomeView: View {
    let continueAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .accessibilityHidden(true)
                    .entrance(step: 0, isVisible: isVisible)

                VStack(spacing: 8) {
                    Text(String(localized: "Welcome to Bardo"))
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(String(localized: "Record or import conversations and turn them into text you can read, search and share."))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
                .entrance(step: 1, isVisible: isVisible)

                VStack(alignment: .leading, spacing: 18) {
                    WelcomeFeatureRow(
                        systemImage: "waveform.and.mic",
                        title: String(localized: "Transcribe conversations"),
                        detail: String(localized: "Turn recordings into clear text, with the moment of every sentence.")
                    )
                    .entrance(step: 2, isVisible: isVisible)

                    WelcomeFeatureRow(
                        systemImage: "person.2.wave.2",
                        title: String(localized: "Identify participants"),
                        detail: String(localized: "Organize conversations by speaker so each voice has its own place.")
                    )
                    .entrance(step: 3, isVisible: isVisible)

                    WelcomeFeatureRow(
                        systemImage: "lock.shield",
                        title: String(localized: "Everything stays on your Mac"),
                        detail: String(localized: "Audio and transcripts are processed here and are never sent to an online service.")
                    )
                    .entrance(step: 4, isVisible: isVisible)
                }
                .padding(.top, 28)

                VStack(spacing: 12) {
                    Button(action: continueAction) {
                        Text(String(localized: "Continue"))
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)

                    Text(String(localized: "Bardo will download about 650 MB of voice resources so it can work offline."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 32)
                .entrance(step: 5, isVisible: isVisible)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .onAppear { hasAppeared = true }
    }

    private var isVisible: Bool { reduceMotion || hasAppeared }
}

private struct WelcomeFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Elements settle in one after another: a short rise and fade, staggered.
    func entrance(step: Int, isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 10)
            .animation(.easeOut(duration: 0.45).delay(0.08 * Double(step)), value: isVisible)
    }
}
