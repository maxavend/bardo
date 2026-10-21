import SwiftUI

/// A conversation's details, as a sheet over the window: nothing slides in beside the
/// transcript or makes the columns move.
struct RecordingInfoSheet: View {
    let recording: Recording
    let transcript: Transcript?
    @ObservedObject var model: LibraryViewModel

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

            RecordingInspector(
                recording: recording,
                transcript: transcript,
                isCompressing: model.compressingRecordingID == recording.id,
                compress: model.isProcessing(recording.id) ? nil : { preset in
                    Task { await model.compressAudio(recording.id, to: preset) }
                }
            )
                // One surface from the title to the button, and scrolling only once the
                // technical details are open.
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)

            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .bardoPrimaryAction()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 480)
        .frame(minHeight: 420, idealHeight: 640)
    }
}
