import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Bardo")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Private, on-device transcription for macOS.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
