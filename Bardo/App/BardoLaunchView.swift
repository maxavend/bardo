import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()
    @AppStorage("Bardo.WelcomeCompleted.v1") private var hasCompletedWelcome = false

    var body: some View {
        #if DEBUG
        if DesignReview.showsWelcome || DesignReview.welcomeStartsOnChoice {
            BardoWelcomeView(startsOnChoice: DesignReview.welcomeStartsOnChoice) { _ in }
        } else if let tab = DesignReview.settingsTab {
            SettingsView(initialTab: tab)
        } else if let state = DesignReview.setupState {
            TranscriptionSetupView(state: state, retry: {}, continueWithoutModels: {})
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
                BardoWelcomeView { engine in
                    UserDefaults.standard.set(engine.rawValue, forKey: TranscriptionEngine.defaultsKey)
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
            // Set up before there was a choice: keep the Whisper model it installed.
            if hasCompletedWelcome, UserDefaults.standard.string(forKey: TranscriptionEngine.defaultsKey) == nil {
                UserDefaults.standard.set(TranscriptionEngine.balanced.rawValue, forKey: TranscriptionEngine.defaultsKey)
            }
            if hasCompletedWelcome || setup.isLibraryUnlocked {
                setup.startPreparation()
            }
        }
    }
}

/// The first launch, as Apple's own setup: what Bardo does, then how to transcribe.
private struct BardoWelcomeView: View {
    var startsOnChoice = false
    let continueAction: (TranscriptionEngine) -> Void

    @State private var isChoosing = false
    @State private var engine = TranscriptionEngine.recommended

    var body: some View {
        ZStack {
            if isChoosing {
                TranscriptionChoicePage(
                    engine: $engine,
                    back: { withAnimation(.smooth(duration: 0.4)) { isChoosing = false } },
                    start: { continueAction(engine) }
                )
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            } else {
                WelcomePage {
                    withAnimation(.smooth(duration: 0.4)) { isChoosing = true }
                }
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            }
        }
        .onAppear { isChoosing = startsOnChoice }
    }
}

/// What Bardo does, in three lines.
private struct WelcomePage: View {
    let continueAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                BardoAppIcon(size: 80)
                    .entrance(step: 0, isVisible: isVisible)

                VStack(spacing: 8) {
                    Text(String(localized: "Welcome to Bardo"))
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(String(localized: "Turn conversations into text you can read, search and share."))
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
                        title: String(localized: "Every word, in its moment"),
                        detail: String(localized: "Read along as it plays and go back to any sentence.")
                    )
                    .entrance(step: 2, isVisible: isVisible)

                    WelcomeFeatureRow(
                        systemImage: "person.2.wave.2",
                        title: String(localized: "Who said what"),
                        detail: String(localized: "Bardo tells each voice in the conversation apart.")
                    )
                    .entrance(step: 3, isVisible: isVisible)

                    WelcomeFeatureRow(
                        systemImage: "lock.shield",
                        title: String(localized: "Private, on your Mac"),
                        detail: String(localized: "Audio and text never leave this Mac.")
                    )
                    .entrance(step: 4, isVisible: isVisible)
                }
                .frame(maxWidth: 420)
                .padding(.top, 28)

                Button(action: continueAction) {
                    Text(String(localized: "Continue"))
                        .padding(.horizontal, 36)
                }
                .bardoPrimaryAction()
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 32)
                .entrance(step: 5, isVisible: isVisible)
            }
            // The welcome line reads on one line; the features keep a narrower column.
            .frame(maxWidth: 580)
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

/// How to transcribe: Apple's, with nothing to download, or Whisper for more precision.
/// Any of them can be changed later in Settings.
private struct TranscriptionChoicePage: View {
    @Binding var engine: TranscriptionEngine
    let back: () -> Void
    let start: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 52, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Elige cómo transcribir")
                        .font(.largeTitle.weight(.bold))
                    Text("Todo sucede en este Mac, sin enviar nada a internet.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 16)

                VStack(spacing: 10) {
                    ForEach(TranscriptionEngine.allCases) { option in
                        EngineCard(engine: option, isSelected: engine == option) {
                            withAnimation(.smooth(duration: 0.25)) { engine = option }
                        }
                    }
                }
                .frame(maxWidth: 480)
                .padding(.top, 28)

                Text("Puedes cambiar de opción y gestionar las descargas cuando quieras en Configuración › Transcripción.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                    .padding(.top, 16)

                HStack(spacing: 12) {
                    Button("Atrás", action: back)
                        .bardoSecondaryAction()
                        .keyboardShortcut(.cancelAction)
                    Button(action: start) {
                        Text(engine.approximateBytes == nil ? "Empezar" : "Descargar y empezar")
                            .padding(.horizontal, 20)
                    }
                    .bardoPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.extraLarge)
                .padding(.top, 28)
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

/// One way of transcribing, as a card to choose.
private struct EngineCard: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(engine.title)
                            .font(.headline)
                        if engine == .recommended {
                            RecommendedBadge()
                        }
                    }
                    Text(engine.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(engine.isSupported ? engine.downloadSummary : "Requiere macOS 26 o posterior")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!engine.isSupported)
        .opacity(engine.isSupported ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The app icon on its own, without the drop shadow macOS draws around it: the icon
/// image carries its squircle in the middle 824 of 1024 points, shadow around it.
struct BardoAppIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
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
