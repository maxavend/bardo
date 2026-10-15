import SwiftUI

/// A conversation's details, as a sheet over the window: nothing slides in beside the
/// transcript or makes the columns move.
struct RecordingInfoSheet: View {
    let recording: Recording
    let transcript: Transcript?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Información")
                    .font(.title2.weight(.semibold))
                Text(LibraryFormatting.recordingTitle(recording))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 4)

            RecordingInspector(recording: recording, transcript: transcript)
                // One surface from the title to the button, and scrolling only once the
                // technical details are open.
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)

            Divider()

            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480)
        .frame(minHeight: 420, idealHeight: 640)
    }
}
