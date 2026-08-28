import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()
    @State private var completionMomentFinished = false

    var body: some View {
        Group {
            if shouldShowLibrary {
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
        .animation(.easeInOut(duration: 0.22), value: shouldShowLibrary)
        .task {
            await setup.prepareIfNeeded()
        }
        .task(id: setup.isReady) {
            guard setup.isReady, setup.completedSetupThisLaunch else { return }
            do {
                try await Task.sleep(nanoseconds: 850_000_000)
            } catch {
                return
            }
            completionMomentFinished = true
        }
    }

    private var shouldShowLibrary: Bool {
        setup.isReady && (!setup.completedSetupThisLaunch || completionMomentFinished)
    }
}
