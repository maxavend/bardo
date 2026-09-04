import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    let meetingMinutes: MeetingMinutes?

    var body: some View {
        Form {
            Section(String(localized: "Recording")) {
                LabeledContent(String(localized: "Created")) {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent(String(localized: "Duration"), value: LibraryFormatting.duration(recording.duration))
                LabeledContent(String(localized: "Source"), value: LibraryFormatting.source(recording.sources))
            }

            if let transcript, transcript.recordingID == recording.id {
                Section(String(localized: "Conversation")) {
                    LabeledContent(String(localized: "Language"), value: LibraryFormatting.language(transcript.languageCode))
                    if transcript.diarizationMetadata != nil {
                        LabeledContent(
                            String(localized: "Participants"),
                            value: String.localizedStringWithFormat(
                                String(localized: "%lld Participants"),
                                transcript.speakers.count
                            )
                        )
                    }
                }

                if transcript.metadata.processingDuration != nil
                    || transcript.diarizationMetadata?.processingDuration != nil
                    || matchingMinutes?.processingDuration != nil {
                    Section(String(localized: "Processing times")) {
                        if let duration = transcript.metadata.processingDuration {
                            LabeledContent(
                                String(localized: "Transcription"),
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                        if let duration = transcript.diarizationMetadata?.processingDuration {
                            LabeledContent(
                                String(localized: "Speaker identification"),
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                        if let duration = matchingMinutes?.processingDuration {
                            LabeledContent(
                                String(localized: "Meeting Minutes"),
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                    }
                }
            }

            if !recording.audioAssets.isEmpty {
                Section(String(localized: "Audio")) {
                    if recording.audioAssets.count == 1, let asset = recording.audioAssets.first {
                        LabeledContent(String(localized: "File"), value: asset.originalFileName)
                    } else {
                        LabeledContent(
                            String(localized: "Audio Tracks"),
                            value: String.localizedStringWithFormat(
                                String(localized: "%lld audio tracks"),
                                recording.audioAssets.count
                            )
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var matchingMinutes: MeetingMinutes? {
        guard let meetingMinutes, meetingMinutes.recordingID == recording.id else { return nil }
        return meetingMinutes
    }
}

struct RecordingInformationSheet: View {
    let recording: Recording
    let transcript: Transcript?
    let meetingMinutes: MeetingMinutes?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Recording Information"))
                        .font(.headline)

                    Text(LibraryFormatting.recordingTitle(recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            RecordingInspector(
                recording: recording,
                transcript: transcript,
                meetingMinutes: meetingMinutes
            )
        }
        .frame(width: 460, height: 560)
    }
}
