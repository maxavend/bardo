import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()

    var body: some View {
        Group {
            if setup.isReady {
                RootView(warmTranscriptionForRecording: setup.warmForRecording)
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
            setup.startPreparation()
        }
    }
}