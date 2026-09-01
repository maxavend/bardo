import AppKit
import SwiftUI

extension View {
    func recordingDetailEnhancements(
        recording: Recording,
        model: LibraryViewModel,
        playback: AudioPlaybackController
    ) -> some View {
        modifier(
            RecordingDetailEnhancements(
                recording: recording,
                model: model,
                playback: playback
            )
        )
    }
}

@MainActor
private struct RecordingDetailEnhancements: ViewModifier {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @State private var isSpeakerNamingPresented = false
    @State private var isMinutesPresented = false
    @State private var openSpeakersAfterDiarization = false

    private var transcript: Transcript? {
        guard let transcript = model.transcript,
              transcript.recordingID == recording.id else {
            return nil
        }
        return transcript
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let transcript {
                    detailActionBar(transcript)
                }
            }
            .sheet(isPresented: $isSpeakerNamingPresented) {
                if let transcript,
                   SpeakerNamingPolicy.shouldPrompt(speakerCount: transcript.speakers.count) {
                    SpeakerNamingSheet(
                        transcript: transcript,
                        audioURL: playback.loadedAudioURL,
                        onSave: { names in
                            isSpeakerNamingPresented = false
                            Task { @MainActor in
                                await persistSpeakerNames(names, transcript: transcript)
                            }
                        },
                        onSkip: {
                            isSpeakerNamingPresented = false
                        }
                    )
                }
            }
            .sheet(isPresented: $isMinutesPresented) {
                if let transcript {
                    MeetingMinutesSheet(
                        recording: recording,
                        transcript: transcript,
                        playback: playback
                    )
                }
            }
            .onChange(of: model.isDiarizing) { wasDiarizing, isDiarizing in
                guard wasDiarizing,
                      !isDiarizing,
                      openSpeakersAfterDiarization else {
                    return
                }
                openSpeakersAfterDiarization = false
                if model.diarizationErrorMessage == nil,
                   let transcript,
                   SpeakerNamingPolicy.shouldPrompt(speakerCount: transcript.speakers.count) {
                    playback.pause()
                    isSpeakerNamingPresented = true
                }
            }
    }

    private func detailActionBar(_ transcript: Transcript) -> some View {
        HStack(spacing: 10) {
            if model.isDiarizing, model.diarizationRecordingID == recording.id {
                ProgressView()
                    .controlSize(.small)
                Text("Identifying speakers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if transcript.speakers.isEmpty {
                Button {
                    playback.pause()
                    openSpeakersAfterDiarization = true
                    model.beginDiarization()
                } label: {
                    Label("Identify Speakers", systemImage: "person.2.wave.2")
                }
                .buttonStyle(.bordered)
                .disabled(!transcript.isComplete || model.isTranscribing)
            } else if SpeakerNamingPolicy.shouldPrompt(speakerCount: transcript.speakers.count) {
                Button {
                    playback.pause()
                    isSpeakerNamingPresented = true
                } label: {
                    Label(
                        "Participants (\(transcript.speakers.count))",
                        systemImage: "person.2"
                    )
                }
                .buttonStyle(.bordered)
            } else {
                Label("1 Speaker", systemImage: "person")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                playback.pause()
                isMinutesPresented = true
            } label: {
                Label("Minutes", systemImage: "sparkles.rectangle.stack")
            }
            .buttonStyle(.borderedProminent)
            .disabled(transcript.text.isEmpty)

            Spacer(minLength: 0)

            if SpeakerNamingPolicy.shouldPrompt(speakerCount: transcript.speakers.count) {
                Text("Listen to 10-second voice samples to rename participants anytime.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func persistSpeakerNames(
        _ names: [Speaker.ID: String],
        transcript: Transcript
    ) async {
        for speaker in transcript.speakers {
            let proposedName = names[speaker.id] ?? ""
            let normalizedCurrent = (speaker.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedProposed = proposedName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedCurrent != normalizedProposed else { continue }
            await model.renameSpeaker(speaker.id, to: proposedName)
        }
    }
}

@MainActor
private struct MeetingMinutesSheet: View {
    let recording: Recording
    let transcript: Transcript
    @ObservedObject var playback: AudioPlaybackController

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: MeetingMinutes?
    @State private var isLoading = true
    @State private var isGenerating = false
    @State private var downloadProgress: Double = 0
    @State private var didReceiveDownloadProgress = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if isLoading {
                    ProgressView("Loading minutes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let minutes {
                    minutesContent(minutes)
                } else {
                    emptyState
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 620)
        .task(id: recording.id) {
            await loadPersistedMinutes()
        }
        .alert("Minutes Couldn’t Be Generated", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Minutes")
                    .font(.title2.weight(.semibold))
                Text(recording.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Minutes Yet", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Generate a concise local summary with topics, decisions, action items, and open questions from this transcript.")
        } actions: {
            generationButton(title: "Generate Minutes")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func minutesContent(_ minutes: MeetingMinutes) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                minutesSection("Summary") {
                    Text(minutes.summary)
                        .textSelection(.enabled)
                }

                if !minutes.topics.isEmpty {
                    minutesSection("Topics") {
                        bulletList(minutes.topics)
                    }
                }

                if !minutes.decisions.isEmpty {
                    minutesSection("Decisions") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(minutes.decisions) { item in
                                sourcedRow(text: item.text, sourceTime: item.sourceTime)
                            }
                        }
                    }
                }

                if !minutes.actionItems.isEmpty {
                    minutesSection("Action Items") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(minutes.actionItems) { item in
                                actionItemRow(item)
                            }
                        }
                    }
                }

                if !minutes.openQuestions.isEmpty {
                    minutesSection("Open Questions") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(minutes.openQuestions) { item in
                                sourcedRow(text: item.text, sourceTime: item.sourceTime)
                            }
                        }
                    }
                }

                Text("Generated locally with \(minutes.engine) · \(minutes.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let minutes {
                Button {
                    copyMinutes(minutes)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    Task { await generateMinutes() }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(isGenerating)
            }

            Spacer()

            if isGenerating {
                if didReceiveDownloadProgress, downloadProgress < 1 {
                    VStack(alignment: .trailing, spacing: 3) {
                        ProgressView(value: downloadProgress)
                            .frame(width: 150)
                        Text("Preparing local AI model… \(Int(downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Generating minutes locally…")
                        .controlSize(.small)
                }
            } else if minutes == nil {
                generationButton(title: "Generate Minutes")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func generationButton(title: String) -> some View {
        Button {
            Task { await generateMinutes() }
        } label: {
            Label(title, systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isGenerating)
    }

    private func minutesSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletList(_ strings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(strings.enumerated()), id: \.offset) { _, value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(value)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func sourcedRow(text: String, sourceTime: TimeInterval?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            sourceButton(sourceTime)
        }
    }

    private func actionItemRow(_ item: MeetingActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.task)
                    .textSelection(.enabled)
                let metadata = [item.assignee, item.deadline]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)
            sourceButton(item.sourceTime)
        }
    }

    @ViewBuilder
    private func sourceButton(_ sourceTime: TimeInterval?) -> some View {
        if let sourceTime {
            Button(LibraryFormatting.timecode(sourceTime)) {
                dismiss()
                playback.seek(to: sourceTime)
                _ = playback.play()
            }
            .buttonStyle(.link)
            .font(.caption.monospacedDigit())
            .help("Play the transcript evidence for this item")
        }
    }

    private func loadPersistedMinutes() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let store = try MeetingMinutesStore.live()
            minutes = try await store.load(recordingID: recording.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateMinutes() async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        downloadProgress = 0
        didReceiveDownloadProgress = false
        defer { isGenerating = false }

        do {
            let generated = try await QwenMeetingMinutesGenerator().generate(
                from: transcript,
                recordingTitle: recording.title,
                downloadProgress: { progress in
                    Task { @MainActor in
                        didReceiveDownloadProgress = true
                        downloadProgress = max(
                            downloadProgress,
                            min(1, max(0, progress.fractionCompleted))
                        )
                    }
                }
            )
            let store = try MeetingMinutesStore.live()
            try await store.save(generated)
            minutes = generated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyMinutes(_ minutes: MeetingMinutes) {
        let text = MeetingMinutesPlainTextFormatter.string(from: minutes)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private enum MeetingMinutesPlainTextFormatter {
    static func string(from minutes: MeetingMinutes) -> String {
        var sections: [String] = []
        sections.append("Summary\n\(minutes.summary)")

        if !minutes.topics.isEmpty {
            sections.append("Topics\n" + minutes.topics.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !minutes.decisions.isEmpty {
            sections.append("Decisions\n" + minutes.decisions.map { "• \($0.text)" }.joined(separator: "\n"))
        }
        if !minutes.actionItems.isEmpty {
            sections.append(
                "Action Items\n" + minutes.actionItems.map { item in
                    var suffix: [String] = []
                    if let assignee = item.assignee, !assignee.isEmpty { suffix.append(assignee) }
                    if let deadline = item.deadline, !deadline.isEmpty { suffix.append(deadline) }
                    return "• \(item.task)" + (suffix.isEmpty ? "" : " — \(suffix.joined(separator: ", "))")
                }.joined(separator: "\n")
            )
        }
        if !minutes.openQuestions.isEmpty {
            sections.append("Open Questions\n" + minutes.openQuestions.map { "• \($0.text)" }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}
