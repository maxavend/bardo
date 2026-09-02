import SwiftUI

struct MeetingMinutesView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Meeting Minutes", systemImage: "list.bullet.clipboard")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.isGeneratingMeetingMinutes {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let minutes = model.meetingMinutes,
               minutes.recordingID == recording.id {
                Text(.init(minutes.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("Generated locally from the completed transcript")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Regenerate") { model.beginMeetingMinutes() }
                        .disabled(!model.canGenerateMeetingMinutes)
                }
            } else {
                Text("Generate a conservative, on-device summary from the finished transcript. Audio is never sent to the minutes model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Generate Meeting Minutes") {
                    model.beginMeetingMinutes()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canGenerateMeetingMinutes)
            }

            if model.isGeneratingMeetingMinutes {
                ProgressView(value: model.meetingMinutesProgress ?? 0)
            }

            if let error = model.meetingMinutesErrorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { model.clearMeetingMinutesError() }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
