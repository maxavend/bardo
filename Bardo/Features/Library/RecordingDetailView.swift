import AppKit
import SwiftUI

struct RecordingDetailView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    /// Not observed here: only the playback bar and transcript rows redraw with the
    /// playhead, instead of the whole document ten times per second.
    let playback: AudioPlaybackController
    @ObservedObject private var favorites = BardoFavoritesStore.shared

    /// The window's search: matches are highlighted in the transcript.
    let searchQuery: String
    @Binding var isInspectorPresented: Bool
    let onMoveToTrash: (Recording) -> Void
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            RecordingDocumentHeader(recording: recording)
                .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.top, BardoSpacing.section)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .top)

            TranscriptContentView(
                recording: recording,
                model: model,
                playback: playback,
                searchQuery: searchQuery,
                editor: $editor,
                isSpeakerNamingPresented: $isSpeakerNamingPresented,
                bottomContentInset: playbackContentInset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    favorites.toggle(recording.id)
                } label: {
                    Label(
                        isFavorite ? "Quitar de Favoritas" : "Agregar a Favoritas",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
                .help(isFavorite ? "Quitar de Favoritas" : "Agregar a Favoritas")

                if let transcript = currentTranscript, !transcript.text.isEmpty {
                    ShareLink(
                        item: transcriptExport(transcript),
                        subject: Text(recordingDisplayTitle),
                        preview: SharePreview(recordingDisplayTitle)
                    ) {
                        Label("Compartir transcripción", systemImage: "square.and.arrow.up")
                    }
                    .help("Compartir transcripción")
                }

                recordingActionsMenu
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Información", systemImage: "info.circle")
                }
                .help(isInspectorPresented ? "Ocultar información (⌥⌘I)" : "Mostrar información (⌥⌘I)")
            }
        }
        .bardoBottomBar {
            if showsPlaybackBar {
                FloatingPlaybackBar(recording: recording, playback: playback)
            }
        }
        .onChange(of: recording.id) { _, _ in
            editor = nil
            pendingReplacementAction = nil
            isSpeakerNamingPresented = false
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
                onMoveToTrash(recording)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("El audio y la transcripción de \"\(recordingDisplayTitle)\" se moverán a la Papelera de macOS, donde podrás recuperarlos.")
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "speakers":
                isSpeakerNamingPresented = true
            case "rename":
                isRenamePresented = true
            case "delete":
                isDeleteConfirmationPresented = true
            case "edit":
                if let segment = model.transcript?.segments.first { editor = .segment(segment) }
            case "seek":
                playback.seek(to: TimeInterval(step.value) ?? 10)
            default:
                break
            }
        }
        #endif
        .enableInjection()
    }

    private var recordingActionsMenu: some View {
        Menu {
            Button {
                isRenamePresented = true
            } label: {
                Label("Renombrar…", systemImage: "pencil")
            }

            Button {
                revealInFinder()
            } label: {
                Label("Mostrar en Finder", systemImage: "folder")
            }

            Button {
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label("Copiar ubicación", systemImage: "doc.on.doc")
            }

            if let transcript = currentTranscript {
                Divider()

                Button {
                    copyTranscript(transcript)
                } label: {
                    Label("Copiar transcripción", systemImage: "doc.on.doc")
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
                        transcript.diarizationMetadata == nil
                            ? "Identificar hablantes"
                            : "Identificar hablantes de nuevo",
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
                    Label("Transcribir de nuevo…", systemImage: "arrow.clockwise")
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
            }

            Divider()

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Mover a la Papelera…", systemImage: "trash")
            }
            .disabled(model.isProcessing(recording.id))
            .keyboardShortcut(.delete, modifiers: [.command])
        } label: {
            Label("Más acciones", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Más acciones")
    }

    private var isFavorite: Bool {
        favorites.contains(recording.id)
    }

    private var currentTranscript: Transcript? {
        guard let transcript = model.transcript, transcript.recordingID == recording.id else { return nil }
        return transcript
    }

    /// Plain text with speaker names and timestamps, ready for Mail, Notes or Messages.
    private func transcriptExport(_ transcript: Transcript) -> String {
        let names = Dictionary(
            transcript.speakers.enumerated().map { index, speaker in
                let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (speaker.id, name.isEmpty
                    ? String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
                    : name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var lines = [recordingDisplayTitle, ""]
        var previousSpeaker: Speaker.ID?
        for segment in transcript.segments {
            let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let speakerID = segment.speakerID, speakerID != previousSpeaker, let name = names[speakerID] {
                lines.append("")
                lines.append("\(name) · \(LibraryFormatting.duration(segment.startTime))")
            }
            previousSpeaker = segment.speakerID
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    private var recordingDisplayTitle: String {
        LibraryFormatting.recordingTitle(recording)
    }

    private var showsPlaybackBar: Bool {
        !recording.audioAssets.isEmpty
    }

    /// macOS 26 reserves the bar's space itself (see `bardoBottomBar`).
    private var playbackContentInset: CGFloat {
        guard showsPlaybackBar else { return 0 }
        if #available(macOS 26.0, *) { return 0 }
        return BardoLayout.playbackContentClearance
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

struct RecordingDocumentHeader: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LibraryFormatting.recordingTitle(recording))
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(LibraryFormatting.recordingTitle(recording)), \(metadata)")
    }

    private var metadata: String {
        let date = recording.createdAt.formatted(.dateTime.day().month(.wide).year())
        return "\(date) · \(LibraryFormatting.duration(recording.duration)) · \(LibraryFormatting.source(recording.sources))"
    }
}
