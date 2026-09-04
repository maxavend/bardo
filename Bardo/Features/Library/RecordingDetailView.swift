import AppKit
import SwiftUI

struct RecordingDetailView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var transcriptSearch: String
    var captureMenu: AnyView? = nil
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isInspectorPresented = false
    @State private var selectedTab: DetailTab = .transcript
    @State private var processingBeganAt: Date?

    enum DetailTab: String, CaseIterable, Identifiable, Hashable {
        case transcript
        case minutes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: String(localized: "Transcripción")
            case .minutes: String(localized: "Minuta")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailCustomHeader
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.top, 12)
                .padding(.bottom, 12)

            subHeader
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.2)

            switch selectedTab {
            case .transcript:
                TranscriptContentView(
                    recording: recording,
                    model: model,
                    playback: playback,
                    searchText: $transcriptSearch,
                    editor: $editor,
                    isSpeakerNamingPresented: $isSpeakerNamingPresented,
                    onSelectMinutes: { selectedTab = .minutes }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .minutes:
                MeetingMinutesView(
                    recording: recording,
                    model: model,
                    onSwitchToTranscript: { selectedTab = .transcript }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("")
        .inspector(isPresented: $isInspectorPresented) {
            RecordingInspector(
                recording: recording,
                transcript: model.transcript?.recordingID == recording.id ? model.transcript : nil
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !recording.audioAssets.isEmpty || playback.errorMessage != nil {
                FloatingPlaybackBar(recording: recording, playback: playback)
            }
        }
        .onAppear {
            updateProcessingClock(isProcessing: isDetailProcessing)
        }
        .onChange(of: isDetailProcessing) { _, isProcessing in
            updateProcessingClock(isProcessing: isProcessing)
        }
        .onChange(of: recording.id) { _, _ in
            transcriptSearch = ""
            editor = nil
            pendingReplacementAction = nil
            isSpeakerNamingPresented = false
            selectedTab = .transcript
            processingBeganAt = nil
            updateProcessingClock(isProcessing: isDetailProcessing)
        }
        .onChange(of: model.isGeneratingMeetingMinutes) { _, isGenerating in
            if isGenerating {
                selectedTab = .minutes
            }
        }
        .onChange(of: model.shouldPresentSpeakerNamingSheet) { _, shouldPresent in
            guard shouldPresent else { return }
            isSpeakerNamingPresented = true
            model.consumeSpeakerNamingSheetRequest()
        }
        .sheet(item: $editor) { state in
            TranscriptEditorSheet(
                state: state,
                onSave: { value in
                    editor = nil
                    Task {
                        switch state.kind {
                        case .speaker(let speakerID):
                            await model.renameSpeaker(speakerID, to: value)
                        case .segment(let segmentID):
                            await model.updateTranscriptSegment(segmentID, text: value)
                        }
                    }
                },
                onRestore: state.canRestore ? {
                    editor = nil
                    if case .segment(let segmentID) = state.kind {
                        Task { await model.restoreOriginalTranscriptSegment(segmentID) }
                    }
                } : nil
            )
        }
        .sheet(isPresented: $isSpeakerNamingPresented) {
            if let transcript = model.transcript, transcript.recordingID == recording.id {
                SpeakerNamingSheet(transcript: transcript, model: model)
            }
        }
        .alert(item: $pendingReplacementAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmLabel)) {
                    switch action {
                    case .retranscribe:
                        model.beginTranscription()
                    case .rediarize:
                        model.beginDiarization()
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $isRenamePresented) {
            RecordingRenameSheet(
                recording: recording,
                onSave: { title in
                    isRenamePresented = false
                    Task { await model.renameRecording(recording.id, to: title) }
                },
                onCancel: { isRenamePresented = false }
            )
        }
        .confirmationDialog(
            String(localized: "Move Recording to Trash?"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash"), role: .destructive) {
                Task { await model.deleteRecording(recording.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "This moves the managed audio, transcript, and minutes for \"%@\" to the macOS Trash, where you can recover it."),
                recordingDisplayTitle
            ))
        }
        .enableInjection()
    }

    private var detailCustomHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recordingDisplayTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .imageScale(.small)
                            .accessibilityHidden(true)

                        Text(toolbarSubtitle)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let captureMenu {
                    captureMenu
                }

                recordingHeaderActions
            }
        }
    }

    private var recordingHeaderActions: some View {
        Menu {
            Button {
                isRenamePresented = true
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
            .disabled(model.isTranscribing || model.isDiarizing)
            .keyboardShortcut("e", modifiers: [.command])

            Button {
                revealInFinder()
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "folder")
            }

            Button {
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label(String(localized: "Copy Location"), systemImage: "doc.on.doc")
            }

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                Divider()

                Button {
                    copyTranscript(transcript)
                } label: {
                    Label(String(localized: "Copy Transcript"), systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)

                Button {
                    if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                        pendingReplacementAction = .rediarize
                    } else {
                        model.beginDiarization()
                    }
                } label: {
                    Label(
                        transcript.diarizationMetadata == nil ? String(localized: "Identify Speakers") : String(localized: "Identify Speakers Again"),
                        systemImage: "person.2.wave.2"
                    )
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)

                Button {
                    if transcript.hasManualChanges {
                        pendingReplacementAction = .retranscribe
                    } else {
                        model.beginTranscription()
                    }
                } label: {
                    Label(String(localized: "Transcribe Again…"), systemImage: "arrow.clockwise")
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
            }

            Divider()

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(String(localized: "Move to Trash"), systemImage: "trash")
            }
            .disabled(model.isTranscribing || model.isDiarizing || model.isGeneratingMeetingMinutes)
            .keyboardShortcut(.delete, modifiers: [.command])
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .bardoGlassCircle(interactive: true)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(String(localized: "More recording and transcript actions"))
        .accessibilityLabel(String(localized: "More recording and transcript actions"))
    }

    private var toolbarSubtitle: String {
        "\(recording.createdAt.formatted(.dateTime.day().month(.wide).year())) — \(LibraryFormatting.duration(recording.duration))"
    }

    private var subHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            tabSwitcher

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField(String(localized: "Buscar en transcripción…"), text: $transcriptSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))

                if !transcriptSearch.isEmpty {
                    Button {
                        transcriptSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 210, height: 28)
            .bardoGlassCapsule(interactive: true)

            Spacer(minLength: 12)

            detailContextMetadata
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordingDisplayTitle: String {
        LibraryFormatting.recordingTitle(recording)
    }

    private var isDetailProcessing: Bool {
        model.isTranscribing
            || (model.isDiarizing && model.diarizationRecordingID == recording.id)
            || model.isGeneratingMeetingMinutes
            || recording.processingState == .processing
    }

    private func metadataLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.fill.quaternary)
                                    .overlay {
                                        Capsule()
                                            .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                                    }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .bardoGlassCapsule(interactive: true)
        .accessibilityLabel(String(localized: "Recording View"))
    }

    private var detailContextMetadata: some View {
        HStack(spacing: 8) {
            if let transcript = model.transcript, transcript.recordingID == recording.id {
                metadataLabel(LibraryFormatting.language(transcript.languageCode), systemImage: "globe")

                Text("—")
                    .foregroundStyle(.tertiary)

                if !transcript.speakers.isEmpty {
                    metadataLabel(
                        String.localizedStringWithFormat(String(localized: "%lld participantes"), transcript.speakers.count),
                        systemImage: "person.2"
                    )

                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }

            processingMetadata
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(toolbarSubtitle)
    }

    @ViewBuilder
    private var processingMetadata: some View {
        if isDetailProcessing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(processingBeganAt ?? context.date)
                metadataLabel(
                    String.localizedStringWithFormat(String(localized: "Tiempo procesando %@"), LibraryFormatting.duration(elapsed)),
                    systemImage: "hourglass"
                )
            }
        } else if recording.processingState == .failed {
            Label(String(localized: "Needs attention"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            metadataLabel(
                String.localizedStringWithFormat(String(localized: "Tiempo procesando %@"), LibraryFormatting.duration(recording.duration)),
                systemImage: "hourglass"
            )
        }
    }

    private func updateProcessingClock(isProcessing: Bool) {
        if isProcessing {
            processingBeganAt = processingBeganAt ?? Date()
        } else {
            processingBeganAt = nil
        }
    }

    private func copyTranscript(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(transcript.text, forType: .string) {
            model.reportRecordingActionFeedback(String(localized: "Transcript copied"))
        }
    }

    private func revealInFinder() {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError(String(localized: "Bardo could not locate the managed recording folder."))
                return
            }
            let target = FileManager.default.fileExists(atPath: location.path)
                ? location
                : location.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
