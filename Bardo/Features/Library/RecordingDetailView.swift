import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Binding var isInfoPresented: Bool
    @Binding var isFullPlayerPresented: Bool
    let onMoveToTrash: (Recording) -> Void
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var pendingRetranscriptionMode: TranscriptionTrackMode?
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false
    /// The conversation's audio file, resolved once so Share can offer it at once.
    @State private var shareAudioURL: URL?

    var body: some View {
        TranscriptContentView(
            recording: recording,
            model: model,
            playback: playback,
            searchQuery: searchQuery,
            editor: $editor,
            isSpeakerNamingPresented: $isSpeakerNamingPresented,
            bottomContentInset: playbackContentInset,
            header: AnyView(
                RecordingDocumentHeader(recording: recording)
                    .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
                    .padding(.horizontal, BardoSpacing.detailHorizontal)
                    .padding(.top, BardoSpacing.section)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .top)
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            // One item per control, so a menu or the share picker opens under its own
            // button instead of the middle of the group. Adjacent items still share one
            // glass background; the overflow menu goes last, as everywhere on macOS.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    favorites.toggle(recording.id)
                } label: {
                    Label(
                        isFavorite ? "Quitar de Favoritas" : "Agregar a Favoritas",
                        systemImage: isFavorite ? "star.fill" : "star"
                    )
                }
                .help(isFavorite ? "Quitar de Favoritas" : "Agregar a Favoritas")
            }

            ToolbarItem(placement: .primaryAction) {
                shareControl
            }

            if let transcript = currentTranscript, !transcript.text.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyTranscript(transcript)
                    } label: {
                        Label("Copiar transcripción", systemImage: "doc.on.doc")
                    }
                    .help("Copiar la transcripción, por hablante y con sus tiempos")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInfoPresented = true
                } label: {
                    Label("Información", systemImage: "info.circle")
                }
                .help("Mostrar información (⌥⌘I)")
            }

            ToolbarItem(placement: .primaryAction) {
                recordingActionsMenu
            }

            // The whole recording in the whole window, in its own glass beside the
            // recording's actions. macOS keeps the toolbar search field in its own
            // trailing slot, so nothing can sit flush against it.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isFullPlayerPresented = true
                } label: {
                    Label("Reproductor completo", systemImage: "waveform")
                }
                .help("Abrir el reproductor completo")
                .disabled(recording.audioAssets.isEmpty)
            }
        }
        .task(id: recording.id) {
            shareAudioURL = nil
            if let audio = conversationAudio {
                shareAudioURL = try? await model.managedAudioURL(for: audio, in: recording.id)
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
                        model.beginTranscription(trackMode: pendingRetranscriptionMode)
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
                if let segments = model.transcript?.segments, !segments.isEmpty {
                    editor = .segment(segments[min(Int(step.value) ?? 0, segments.count - 1)])
                }
            case "seek":
                playback.seek(to: TimeInterval(step.value) ?? 10)
            case "play":
                _ = playback.play()
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

                Group {
                    if hasSeparateTracks {
                        Menu {
                            Button("Cada pista por separado") { retranscribe(transcript, mode: .perTrack) }
                            Button("La mezcla de la conversación") { retranscribe(transcript, mode: .mix) }
                        } label: {
                            Label("Transcribir de nuevo", systemImage: "arrow.clockwise")
                        }
                    } else {
                        Button {
                            retranscribe(transcript, mode: nil)
                        } label: {
                            Label("Transcribir de nuevo…", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
            }

            Divider()

            exportMenu

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

    /// Save the transcript, the conversation's audio or one of its tracks.
    private var exportMenu: some View {
        Menu {
            if let transcript = currentTranscript, !transcript.text.isEmpty {
                Button("Transcripción…") { exportTranscript(transcript) }
                Divider()
            }
            if let conversation = conversationAudio {
                Button("Audio de la conversación…") {
                    exportAudio(conversation, name: recordingDisplayTitle)
                }
            }
            if let tracks = TranscriptionAudioSelection.separateTracks(for: recording, mode: .perTrack) {
                Button("Solo tu micrófono…") {
                    exportAudio(tracks.microphone, name: "\(recordingDisplayTitle) – \(String(localized: "Microphone"))")
                }
                Button("Solo el audio del Mac…") {
                    exportAudio(tracks.system, name: "\(recordingDisplayTitle) – \(String(localized: "Mac audio"))")
                }
            }
        } label: {
            Label("Exportar", systemImage: "square.and.arrow.up.on.square")
        }
        .disabled(recording.audioAssets.isEmpty && currentTranscript == nil)
    }

    private var hasSeparateTracks: Bool {
        TranscriptionAudioSelection.separateTracks(for: recording, mode: .perTrack) != nil
    }

    /// The mix of a recording with separate tracks, or its only audio otherwise.
    private var conversationAudio: AudioAsset? {
        recording.playbackAudioAssets.first
    }

    private func retranscribe(_ transcript: Transcript, mode: TranscriptionTrackMode?) {
        pendingRetranscriptionMode = mode
        if transcript.hasManualChanges {
            pendingReplacementAction = .retranscribe
        } else {
            model.beginTranscription(trackMode: mode)
        }
    }

    private func exportTranscript(_ transcript: Transcript) {
        let text = transcriptExport(transcript)
        Task {
            report(await RecordingExporter.save(suggestedName: recordingDisplayTitle, contentType: .plainText) { url in
                try text.write(to: url, atomically: true, encoding: .utf8)
            })
        }
    }

    private func exportAudio(_ asset: AudioAsset, name: String) {
        Task {
            do {
                let source = try await model.managedAudioURL(for: asset, in: recording.id)
                let type = UTType(filenameExtension: source.pathExtension) ?? .audio
                report(await RecordingExporter.save(suggestedName: name, contentType: type) { destination in
                    try RecordingExporter.copy(source, to: destination)
                })
            } catch {
                model.reportRecordingActionError(error.localizedDescription)
            }
        }
    }

    private func report(_ outcome: RecordingExporter.Outcome) {
        switch outcome {
        case .saved:
            model.reportRecordingActionFeedback(String(localized: "Exported"))
        case .cancelled:
            break
        case .failed(let message):
            model.reportRecordingActionError(message)
        }
    }

    private var isFavorite: Bool {
        favorites.contains(recording.id)
    }

    private var currentTranscript: Transcript? {
        guard let transcript = model.transcript, transcript.recordingID == recording.id else { return nil }
        return transcript
    }

    /// Plain text by speaker with their times, ready for Mail, Notes or Messages.
    private func transcriptExport(_ transcript: Transcript) -> String {
        TranscriptTextFormatter(
            title: recordingDisplayTitle,
            date: recording.createdAt,
            duration: recording.duration,
            notes: recording.notes
        )
        .text(for: transcript)
    }

    /// Share the transcript, the audio, or either when both exist.
    @ViewBuilder
    private var shareControl: some View {
        let transcript = currentTranscript.flatMap { $0.text.isEmpty ? nil : $0 }
        switch (transcript, shareAudioURL) {
        case let (transcript?, audio?):
            Menu {
                ShareLink(
                    item: transcriptExport(transcript),
                    subject: Text(recordingDisplayTitle),
                    preview: SharePreview(recordingDisplayTitle)
                ) {
                    Label("Transcripción", systemImage: "text.alignleft")
                }
                ShareLink(item: audio, preview: SharePreview(recordingDisplayTitle)) {
                    Label("Audio", systemImage: "waveform")
                }
            } label: {
                Label("Compartir", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Compartir")
        case let (transcript?, nil):
            ShareLink(
                item: transcriptExport(transcript),
                subject: Text(recordingDisplayTitle),
                preview: SharePreview(recordingDisplayTitle)
            ) {
                Label("Compartir", systemImage: "square.and.arrow.up")
            }
            .help("Compartir la transcripción")
        case let (nil, audio?):
            ShareLink(item: audio, preview: SharePreview(recordingDisplayTitle)) {
                Label("Compartir", systemImage: "square.and.arrow.up")
            }
            .help("Compartir el audio")
        case (nil, nil):
            Button {} label: {
                Label("Compartir", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
        }
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
        if NSPasteboard.general.setString(transcriptExport(transcript), forType: .string) {
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
