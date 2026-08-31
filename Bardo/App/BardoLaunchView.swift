import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingLibrary = false

    var body: some View {
        ZStack {
            if isShowingLibrary {
                RootView(warmTranscriptionForRecording: setup.warmForRecording)
                    .transition(.opacity)
            } else {
                TranscriptionSetupView(
                    state: setup.state,
                    retry: setup.retry
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isShowingLibrary)
        .task {
            if setup.isReady && !setup.completedSetupThisLaunch {
                isShowingLibrary = true
            }
            await setup.prepareIfNeeded()
            await showLibraryWhenReady()
        }
        .onChange(of: setup.state) { _, state in
            guard case .ready = state else { return }
            Task { @MainActor in
                await showLibraryWhenReady()
            }
        }
    }

    @MainActor
    private func showLibraryWhenReady() async {
        guard setup.isReady, !isShowingLibrary else { return }
        if setup.completedSetupThisLaunch && !reduceMotion {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard setup.isReady else { return }
        isShowingLibrary = true
    }
}
