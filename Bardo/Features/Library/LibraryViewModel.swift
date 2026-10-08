import AppKit
import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var issues: [RecordingStoreIssue] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var importErrorMessage: String?
    @Published private(set) var recordingActionErrorMessage: String?
    @Published private(set) var recordingActionFeedback: String?
    @Published private(set) var transcript: Transcript?
    @Published private(set) var transcriptErrorMessage: String?
    @Published private(set) var transcriptEditErrorMessage: String?
    @Published private(set) var transcriptionProgress: TranscriptionProgressSnapshot?
    @Published private(set) var liveTranscription: TranscriptionLiveSnapshot?
    @Published private(set) var transcriptionRecordingID: Recording.ID?
    @Published private(set) var diarizationErrorMessage: String?
    @Published private(set) var diarizationProgress: DiarizationProgressSnapshot?
    @Published private(set) var diarizationRecordingID: Recording.ID?
    @Published private(set) var shouldPresentSpeakerNamingSheet = false
    @Published private(set) var searchDocuments: [LibrarySearchDocument] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isDiarizing = false
    /// A manual edit is being written; model work must not start from a stale copy.
    @Published private(set) var isSavingTranscriptEdit = false
    @Published var selection: Recording.ID?

    let playback: AudioPlaybackController

    private var store: RecordingStore?
    private var importer: AudioImportService?
    private var transcriptStore: TranscriptStore?
    private var transcriber: (any RecordingTranscribing)?
    private var diarizer: (any RecordingDiarizing)?
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?

    init(
        store: RecordingStore? = nil,
        importer: AudioImportService? = nil,
        playback: AudioPlaybackController? = nil,
        transcriptStore: TranscriptStore? = nil,
        transcriber: (any RecordingTranscribing)? = nil,
        diarizer: (any RecordingDiarizing)? = nil
    ) {
        self.store = store
        self.importer = importer
        self.playback = playback ?? AudioPlaybackController()
        self.transcriptStore = transcriptStore
        self.transcriber = transcriber
        self.diarizer = diarizer
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let activeStore = try resolveStore()
            let snapshot = try await activeStore.loadLibrary()
            recordings = snapshot.recordings
            issues = snapshot.issues
            errorMessage = nil

            if !isTranscribing {
                try await recoverInterruptedTranscriptions(using: activeStore)
            }

            await rebuildSearchDocuments()
            reconcileSelection()
            await prepareSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importAudio(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        importErrorMessage = nil
        defer { isImporting = false }

        var failures: [String] = []

        do {
            let activeImporter = try resolveImporter()
            for url in urls {
                do {
                    _ = try await activeImporter.importFile(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        if !failures.isEmpty {
            importErrorMessage = failures.joined(separator: "\n")
        }
        await reload()
    }

    func reportImportFailure(_ error: Error) {
        importErrorMessage = error.localizedDescription
    }

    func clearImportError() {
        importErrorMessage = nil
    }

    func renameRecording(_ recordingID: Recording.ID, to proposedTitle: String) async {
        guard recordings.contains(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = String(localized: "That recording is no longer available.")
            return
        }

        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            recordingActionErrorMessage = String(localized: "Recording title cannot be empty.")
            recordingActionFeedback = nil
            return
        }

        recordingActionErrorMessage = nil
        recordingActionFeedback = nil

        do {
            try await updateRecording(recordingID) { $0.title = title }
            recordingActionFeedback = String(localized: "Recording renamed")
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    /// Whether transcription or speaker identification is working on this recording.
    func isProcessing(_ recordingID: Recording.ID) -> Bool {
        (isTranscribing && transcriptionRecordingID == recordingID)
            || (isDiarizing && diarizationRecordingID == recordingID)
    }

    /// Applies one change to the newest copy of a recording and persists it. Renames and
    /// processing-state updates can interleave without overwriting each other.
    private func updateRecording(
        _ recordingID: Recording.ID,
        _ change: (inout Recording) -> Void
    ) async throws {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else {
            throw RecordingStoreError.recordingNotFound(recordingID)
        }
        let previous = recordings[index]
        var updated = previous
        change(&updated)
        recordings[index] = updated
        do {
            try await resolveStore().update(updated)
        } catch {
            if let current = recordings.firstIndex(where: { $0.id == recordingID }),
               recordings[current] == updated {
                recordings[current] = previous
            }
            throw error
        }
    }

    func deleteRecording(_ recordingID: Recording.ID) async {
        guard recordings.contains(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = String(localized: "That recording is no longer available.")
            return
        }

        guard !isProcessing(recordingID) else {
            recordingActionErrorMessage = String(localized: "Finish or cancel processing before deleting this recording.")
            return
        }

        recordingActionErrorMessage = nil
        recordingActionFeedback = nil

        do {
            try await resolveStore().moveToTrash(id: recordingID)
            recordings.removeAll { $0.id == recordingID }
            issues.removeAll { $0.recordingID == recordingID }
            if selection == recordingID {
                selection = nil
                transcript = nil
                playback.unload()
            }
            recordingActionFeedback = String(localized: "Recording moved to the Trash")
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    func managedLocation(for recordingID: Recording.ID) async throws -> URL {
        try await resolveStore().recordingDirectoryURL(recordingID: recordingID)
    }

    func playRecording(_ recordingID: Recording.ID) async {
        guard recordings.contains(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = String(localized: "That recording is no longer available.")
            return
        }

        if selection != recordingID {
            selection = recordingID
            await preparePlaybackForSelection()
        }

        guard selection == recordingID else { return }
        guard playback.isLoaded else {
            recordingActionErrorMessage = playback.errorMessage ?? String(localized: "This recording has no playable managed audio.")
            return
        }
        _ = playback.play()
    }

    func copyManagedLocation(_ recordingID: Recording.ID) async {
        do {
            let location = try await managedLocation(for: recordingID)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(location.path, forType: .string) else {
                recordingActionErrorMessage = String(localized: "Bardo could not copy the managed location to the clipboard.")
                recordingActionFeedback = nil
                return
            }
            recordingActionErrorMessage = nil
            recordingActionFeedback = String(localized: "Managed location copied")
        } catch {
            recordingActionErrorMessage = error.localizedDescription
            recordingActionFeedback = nil
        }
    }

    func reportRecordingActionError(_ message: String) {
        recordingActionErrorMessage = message
        recordingActionFeedback = nil
    }

    func reportRecordingActionFeedback(_ message: String) {
        recordingActionErrorMessage = nil
        recordingActionFeedback = message
    }

    func clearRecordingActionError() {
        recordingActionErrorMessage = nil
    }

    func prepareSelection() async {
        async let playbackPreparation: Void = preparePlaybackForSelection()
        async let transcriptPreparation: Void = loadTranscriptForSelection()
        _ = await (playbackPreparation, transcriptPreparation)
    }

    func preparePlaybackForSelection() async {
        guard let recording = selectedRecording else {
            playback.unload()
            return
        }

        // Loading the audio that is already playing is a no-op, so reloads (an import,
        // a finished recording) never interrupt playback.
        _ = await preparePlayback(playback, for: recording)
    }

    @discardableResult
    func prepareSpeakerPreviewPlayback(_ previewPlayback: AudioPlaybackController) async -> Bool {
        guard let recording = selectedRecording else {
            previewPlayback.setUnavailable("This recording is no longer available.")
            return false
        }

        return await preparePlayback(previewPlayback, for: recording)
    }

    @discardableResult
    private func preparePlayback(
        _ controller: AudioPlaybackController,
        for recording: Recording
    ) async -> Bool {
        guard !recording.audioAssets.isEmpty else {
            controller.setUnavailable("This recording has no managed audio file.")
            return false
        }

        let recordingID = recording.id
        var lastError: String?

        for asset in recording.playbackAudioAssets {
            do {
                let activeStore = try resolveStore()
                let url = try await activeStore.managedAudioURL(
                    recordingID: recordingID,
                    audioAssetID: asset.id
                )
                guard selection == recordingID else { return false }

                let metadata = AudioPlaybackMetadata(
                    title: recording.title,
                    trackLabel: asset.originalFileName
                )
                if controller.load(url: url, metadata: metadata) {
                    return true
                }
                lastError = controller.errorMessage
            } catch {
                guard selection == recordingID else { return false }
                lastError = error.localizedDescription
            }
        }

        controller.setUnavailable(lastError ?? String(localized: "This recording has no playable managed audio."))
        return false
    }

    func loadTranscriptForSelection() async {
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        guard let recordingID = selection else {
            transcript = nil
            liveTranscription = nil
            return
        }

        if transcriptionRecordingID != recordingID {
            liveTranscription = nil
        }

        do {
            let activeStore = try resolveTranscriptStore()
            let loaded = try await activeStore.read(recordingID: recordingID)
            guard selection == recordingID else { return }
            transcript = loaded

            if loaded == nil {
                let residues = await activeStore.temporaryArtifacts(recordingID: recordingID)
                if !residues.isEmpty {
                    transcriptErrorMessage = String(localized: "An interrupted transcription artifact was found and preserved. Retry transcription when ready.")
                }
            }
        } catch {
            guard selection == recordingID else { return }
            transcript = nil
            transcriptErrorMessage = error.localizedDescription
        }
    }

    /// Why transcription cannot start for this recording right now, if anything.
    func transcriptionBlocker(for recordingID: Recording.ID) -> String? {
        if isTranscribing, transcriptionRecordingID != recordingID {
            return String(localized: "Bardo is transcribing another conversation. You can transcribe this one when it finishes.")
        }
        if isDiarizing {
            return String(localized: "Wait for speaker identification to finish.")
        }
        if isSavingTranscriptEdit {
            return String(localized: "Saving your changes…")
        }
        return nil
    }

    func beginTranscription() {
        guard let recording = startTranscriptionIfPossible() else { return }
        transcriptionTask = Task { [weak self] in
            await self?.runTranscription(of: recording)
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    var hasActiveTranscriptionTask: Bool {
        transcriptionTask != nil
    }

    func clearTranscriptError() {
        transcriptErrorMessage = nil
    }

    func clearTranscriptEditError() {
        transcriptEditErrorMessage = nil
    }

    func performSelectedTranscription() async {
        guard let recording = startTranscriptionIfPossible() else { return }
        await runTranscription(of: recording)
    }

    /// Marks transcription as running synchronously, so a second start in the same
    /// run-loop turn is rejected instead of replacing the first task.
    private func startTranscriptionIfPossible() -> Recording? {
        guard !isTranscribing, !isDiarizing, !isSavingTranscriptEdit, let recording = selectedRecording else {
            return nil
        }
        isTranscribing = true
        transcriptionRecordingID = recording.id
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        transcriptionProgress = .init(stage: .preparingModel, fractionCompleted: 0)
        liveTranscription = .empty(recordingID: recording.id, audioDuration: recording.duration ?? 0)
        return recording
    }

    private func runTranscription(of startingRecording: Recording) async {
        var recording = startingRecording
        let recordingID = recording.id
        defer {
            isTranscribing = false
            transcriptionRecordingID = nil
            transcriptionProgress = nil
            liveTranscription = nil
            transcriptionTask = nil
        }

        do {
            let activeRecordingStore = try resolveStore()
            try await updateRecording(recordingID) { $0.processingState = .processing }
            recording = recordings.first { $0.id == recordingID } ?? recording

            let activeTranscriber = try resolveTranscriber()
            let generated = try await activeTranscriber.transcribe(
                recording: recording,
                store: activeRecordingStore,
                progress: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self,
                              self.transcriptionRecordingID == recordingID,
                              self.selection == recordingID else {
                            return
                        }
                        self.transcriptionProgress = snapshot
                    }
                },
                liveUpdate: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self,
                              self.transcriptionRecordingID == recordingID,
                              self.selection == recordingID,
                              snapshot.recordingID == recordingID else {
                            return
                        }
                        self.liveTranscription = snapshot
                    }
                }
            )
            try Task.checkCancellation()

            transcriptionProgress = .init(stage: .saving, fractionCompleted: 0)
            let activeTranscriptStore = try resolveTranscriptStore()
            try await activeTranscriptStore.save(generated)

            try await updateRecording(recordingID) { $0.processingState = .completed }
            if selection == recordingID {
                transcript = generated
                liveTranscription = nil
            }
            transcriptionProgress = .init(stage: .saving, fractionCompleted: 1)
            await rebuildSearchDocuments()
        } catch is CancellationError {
            try? await updateRecording(recordingID) { $0.processingState = .pending }
        } catch {
            try? await updateRecording(recordingID) { $0.processingState = .failed }
            transcriptErrorMessage = error.localizedDescription
        }
    }

    func beginDiarization() {
        guard let start = startDiarizationIfPossible() else { return }
        diarizationTask = Task { [weak self] in
            await self?.runDiarization(of: start.recording, transcript: start.transcript)
        }
    }

    func cancelDiarization() {
        diarizationTask?.cancel()
    }

    func clearDiarizationError() {
        diarizationErrorMessage = nil
    }

    func consumeSpeakerNamingSheetRequest() {
        shouldPresentSpeakerNamingSheet = false
    }

    func performSelectedDiarization() async {
        guard let start = startDiarizationIfPossible() else { return }
        await runDiarization(of: start.recording, transcript: start.transcript)
    }

    private func startDiarizationIfPossible() -> (recording: Recording, transcript: Transcript)? {
        guard !isTranscribing,
              !isDiarizing,
              !isSavingTranscriptEdit,
              let recording = selectedRecording,
              let currentTranscript = transcript,
              currentTranscript.recordingID == recording.id else {
            return nil
        }
        isDiarizing = true
        diarizationRecordingID = recording.id
        diarizationErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationProgress = .init(stage: .preparingModel, fractionCompleted: 0)
        return (recording, currentTranscript)
    }

    private func runDiarization(of recording: Recording, transcript currentTranscript: Transcript) async {
        let recordingID = recording.id
        defer {
            isDiarizing = false
            diarizationRecordingID = nil
            diarizationProgress = nil
            diarizationTask = nil
        }

        do {
            let activeDiarizer = try resolveDiarizer()
            let updated = try await activeDiarizer.diarize(
                recording: recording,
                transcript: currentTranscript,
                store: try resolveStore(),
                progress: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.diarizationRecordingID == recordingID else { return }
                        self.diarizationProgress = snapshot
                    }
                }
            )
            try Task.checkCancellation()

            diarizationProgress = .init(stage: .saving, fractionCompleted: 0)
            try await resolveTranscriptStore().save(updated)
            if selection == recordingID {
                transcript = updated

                if !playback.isLoaded {
                    _ = await preparePlayback(playback, for: recording)
                }

                if SpeakerNamingPolicy.shouldOpenNamingFlow(after: updated) {
                    shouldPresentSpeakerNamingSheet = true
                }
            }
            diarizationProgress = .init(stage: .saving, fractionCompleted: 1)
            await rebuildSearchDocuments()
        } catch is CancellationError {
            // The previously persisted transcript remains authoritative.
        } catch {
            diarizationErrorMessage = error.localizedDescription
        }
    }

    func renameSpeaker(_ speakerID: Speaker.ID, to proposedName: String) async {
        guard var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID) else {
            return
        }

        guard let index = updated.speakers.firstIndex(where: { $0.id == speakerID }) else {
            transcriptEditErrorMessage = String(localized: "That speaker is no longer available in this transcript.")
            return
        }

        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        await persistEditedTranscript(updated)
    }

    func renameSpeakers(_ proposedNames: [Speaker.ID: String]) async {
        guard var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID) else {
            return
        }

        for (speakerID, proposedName) in proposedNames {
            guard let index = updated.speakers.firstIndex(where: { $0.id == speakerID }) else {
                transcriptEditErrorMessage = String(localized: "That speaker is no longer available in this transcript.")
                return
            }
            let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        }
        await persistEditedTranscript(updated)
    }

    func mergeSpeaker(_ sourceID: Speaker.ID, into targetID: Speaker.ID) async {
        guard sourceID != targetID,
              var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID),
              let sourceIndex = updated.speakers.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = updated.speakers.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        if (updated.speakers[targetIndex].name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sourceName = updated.speakers[sourceIndex].name,
           !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.speakers[targetIndex].name = sourceName
        }

        for index in updated.segments.indices where updated.segments[index].speakerID == sourceID {
            updated.segments[index].speakerID = targetID
        }
        updated.speakers.removeAll { $0.id == sourceID }
        await persistEditedTranscript(updated)
    }

    func assignTranscriptSegments(_ segmentIDs: [TranscriptSegment.ID], to speakerID: Speaker.ID) async {
        guard !segmentIDs.isEmpty,
              var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID),
              updated.speakers.contains(where: { $0.id == speakerID })
        else {
            return
        }

        let ids = Set(segmentIDs)
        var changed = false
        for index in updated.segments.indices where ids.contains(updated.segments[index].id) {
            if updated.segments[index].speakerID != speakerID {
                updated.segments[index].speakerID = speakerID
                changed = true
            }
        }
        guard changed else { return }
        await persistEditedTranscript(updated)
    }

    func updateTranscriptSegment(_ segmentID: TranscriptSegment.ID, text proposedText: String) async {
        guard var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID) else {
            return
        }

        guard let index = updated.segments.firstIndex(where: { $0.id == segmentID }) else {
            transcriptEditErrorMessage = String(localized: "That transcript segment is no longer available.")
            return
        }

        let trimmed = proposedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptEditErrorMessage = String(localized: "Transcript text cannot be empty.")
            return
        }

        let original = updated.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.segments[index].editedText = trimmed == original ? nil : trimmed
        await persistEditedTranscript(updated)
    }

    func restoreOriginalTranscriptSegment(_ segmentID: TranscriptSegment.ID) async {
        guard var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID) else {
            return
        }

        guard let index = updated.segments.firstIndex(where: { $0.id == segmentID }) else {
            transcriptEditErrorMessage = String(localized: "That transcript segment is no longer available.")
            return
        }

        updated.segments[index].editedText = nil
        await persistEditedTranscript(updated)
    }

    func stopPlayback() {
        playback.unload()
    }

    var speakerNamingPresentation: SpeakerNamingPresentation {
        guard let transcript else { return .identifySpeakers }
        return SpeakerNamingPolicy.presentation(for: transcript)
    }

    var speakerPreviews: [SpeakerPreview] {
        guard let transcript else { return [] }
        return SpeakerPreviewSelector.previews(for: transcript)
    }

    func shouldOpenNamingFlow(after transcript: Transcript? = nil) -> Bool {
        guard let transcript = transcript ?? self.transcript else { return false }
        return SpeakerNamingPolicy.shouldOpenNamingFlow(after: transcript)
    }

    var hasActiveDiarizationTask: Bool {
        diarizationTask != nil
    }

    var selectedRecording: Recording? {
        guard let selection else { return nil }
        return recordings.first { $0.id == selection }
    }

    /// Edits are refused, with an explanation, while model work runs on the same
    /// transcript: its result would otherwise overwrite them.
    private func canEditTranscript(of recordingID: Recording.ID) -> Bool {
        if isProcessing(recordingID) {
            transcriptEditErrorMessage = String(localized: "Wait for this conversation to finish processing before editing it.")
            return false
        }
        if isSavingTranscriptEdit {
            transcriptEditErrorMessage = String(localized: "Bardo is still saving your previous change.")
            return false
        }
        return true
    }

    private func persistEditedTranscript(_ updated: Transcript) async {
        let recordingID = updated.recordingID
        isSavingTranscriptEdit = true
        defer { isSavingTranscriptEdit = false }
        do {
            try await resolveTranscriptStore().save(updated)
            guard selection == recordingID else { return }
            transcript = updated
            transcriptEditErrorMessage = nil
            await rebuildSearchDocuments()
        } catch {
            guard selection == recordingID else { return }
            transcriptEditErrorMessage = error.localizedDescription
        }
    }

    private func rebuildSearchDocuments() async {
        let activeTranscriptStore: TranscriptStore
        do {
            activeTranscriptStore = try resolveTranscriptStore()
        } catch {
            searchDocuments = recordings.map {
                LibrarySearchDocument(
                    id: $0.id,
                    title: LibraryFormatting.recordingTitle($0),
                    createdAt: $0.createdAt,
                    duration: $0.duration,
                    source: LibraryFormatting.source($0.sources),
                    participantNames: [],
                    transcriptText: ""
                )
            }
            return
        }

        var documents: [LibrarySearchDocument] = []

        for recording in recordings {
            let loadedTranscript: Transcript?
            do {
                loadedTranscript = try await activeTranscriptStore.read(recordingID: recording.id)
            } catch {
                loadedTranscript = nil
            }

            let names: [String] = loadedTranscript?.speakers.enumerated().map { index, speaker -> String in
                let trimmed = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty
                    ? String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
                    : trimmed
            } ?? []

            documents.append(
                LibrarySearchDocument(
                    id: recording.id,
                    title: LibraryFormatting.recordingTitle(recording),
                    createdAt: recording.createdAt,
                    duration: recording.duration,
                    source: LibraryFormatting.source(recording.sources),
                    participantNames: names,
                    transcriptText: loadedTranscript?.text ?? ""
                )
            )
        }

        searchDocuments = documents
    }

    private func recoverInterruptedTranscriptions(using recordingStore: RecordingStore) async throws {
        guard recordings.contains(where: { $0.processingState == .processing }) else { return }
        let activeTranscriptStore = try resolveTranscriptStore()

        for index in recordings.indices where recordings[index].processingState == .processing {
            var recovered = recordings[index]
            do {
                let persistedTranscript = try await activeTranscriptStore.read(recordingID: recovered.id)
                recovered.processingState = persistedTranscript == nil ? .failed : .completed
            } catch {
                recovered.processingState = .failed
            }
            try await recordingStore.update(recovered)
            recordings[index] = recovered
        }
    }

    private func resolveStore() throws -> RecordingStore {
        if let store {
            return store
        }

        let store = try RecordingStore.live()
        self.store = store
        return store
    }

    private func resolveImporter() throws -> AudioImportService {
        if let importer {
            return importer
        }

        let importer = AudioImportService(store: try resolveStore())
        self.importer = importer
        return importer
    }

    private func resolveTranscriptStore() throws -> TranscriptStore {
        if let transcriptStore {
            return transcriptStore
        }
        let store = try TranscriptStore.live()
        transcriptStore = store
        return store
    }

    private func resolveTranscriber() throws -> any RecordingTranscribing {
        if let transcriber {
            return transcriber
        }
        let service = try WhisperTranscriptionService.live()
        transcriber = service
        return service
    }

    private func resolveDiarizer() throws -> any RecordingDiarizing {
        if let diarizer {
            return diarizer
        }
        let service = try SpeakerDiarizationService.live()
        diarizer = service
        return service
    }

    private func reconcileSelection() {
        if let selection, recordings.contains(where: { $0.id == selection }) {
            return
        }
        selection = recordings.first?.id
    }
}
