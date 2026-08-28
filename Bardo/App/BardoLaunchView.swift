import SwiftUI

struct BardoLaunchView: View {
    @StateObject private var setup = TranscriptionSetupCoordinator()

    var body: some View {
        Group {
            if setup.isReady {
                RootView()
                    .transition(.opacity)
            } else {
                TranscriptionSetupView(
                    state: setup.state,
                    retry: setup.retry
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: setup.isReady)
        .task {
            await setup.prepareIfNeeded()
        }
    }
}
