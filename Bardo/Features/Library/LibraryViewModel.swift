import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var issues: [RecordingStoreIssue] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var importErrorMessage: String?
    @Published private(set) var recordingManagementErrorMessage: String?
    @Published private(set) var transcript: Transcript?
    @Published private(set) var transcriptErrorMessage: String?
    @Published private(set) var transcriptEditErrorMessage: String?
    @Published private(set) var transcriptionProgress: TranscriptionProgressSnapshot?
    @Published private(set) var transcriptionRecordingID: Recording.ID?
    @Published private(set) var diarizationErrorMessage: String?
    @Published private(set) var diarizationProgress: DiarizationProgressSnapshot?
    @Published private(set) var diarizationRecordingID: Recording.ID?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isDiarizing = false
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

    func clearRecordingManagementError() {
        recordingManagementErrorMessage = nil
    }

    func renameRecording(id: Recording.ID, to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            recordingManagementErrorMessage = "A recording name cannot be empty."
            return false
        }

        do {
            let activeStore = try resolveStore()
            var recording = try await activeStore.read(id: id)
            recording.title = title
            try await activeStore.update(recording)
            replaceRecording(recording)
            recordingManagementErrorMessage = nil
            return true
        } catch {
            recordingManagementErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteRecording(id: Recording.ID) async -> Bool {
        do {
            await cancelProcessingIfNeeded(for: id)
            let activeStore = try resolveStore()
            let wasSelected = selection == id
            if wasSelected {
                playback.unload()
                transcript = nil
                transcriptErrorMessage = nil
                transcriptEditErrorMessage = nil
                diarizationErrorMessage = nil
            }

            try await activeStore.delete(id: id)
            recordings.removeAll { $0.id == id }
            recordingManagementErrorMessage = nil

            if wasSelected {
                selection = recordings.first?.id
                await prepareSelection()
            }
            return true
        } catch {
            recordingManagementErrorMessage = error.localizedDescription
            return false
        }
    }

    func isProcessing(recordingID: Recording.ID) -> Bool {
        transcriptionRecordingID == recordingID || diarizationRecordingID == recordingID
    }

    func prepareSelection() async {
        await preparePlaybackForSelection()
        await loadTranscriptForSelection()
    }

    func preparePlaybackForSelection() async {
        playback.unload()
        guard let recording = selectedRecording else { return }
        guard !recording.audioAssets.isEmpty else {
            playback.setUnavailable("This recording has no managed audio file.")
            return
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
                guard selection == recordingID else { return }
                if playback.load(url: url) {
                    return
                }
                lastError = playback.errorMessage
            } catch {
                guard selection == recordingID else { return }
                lastError = error.localizedDescription
            }
        }

        playback.setUnavailable(lastError ?? "This recording has no playable managed audio.")
    }

    func loadTranscriptForSelection() async {
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        guard let recordingID = selection else {
            transcript = nil
            return
        }

        do {
            let activeStore = try resolveTranscriptStore()
            let loaded = try await activeStore.read(recordingID: recordingID)
            guard selection == recordingID else { return }
            transcript = loaded

            if let loaded, loaded.metadata.coverage?.completion == .partial {
                transcriptErrorMessage = "This transcript is partial. Bardo preserved the completed portion; retry transcription to process the full recording."
            } else if loaded == nil {
                let residues = await activeStore.temporaryArtifacts(recordingID: recordingID)
                if !residues.isEmpty {
                    transcriptErrorMessage = "An interrupted transcription artifact was found and preserved. Retry transcription when ready."
                }
            }
        } catch {
            guard selection == recordingID else { return }
            transcript = nil
            transcriptErrorMessage = error.localizedDescription
        }
    }

    func beginTranscription() {
        guard !isTranscribing, !isDiarizing, selectedRecording != nil else { return }
        transcriptionTask = Task { [weak self] in
            await self?.performSelectedTranscription()
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    func clearTranscriptError() {
        transcriptErrorMessage = nil
    }

    func clearTranscriptEditError() {
        transcriptEditErrorMessage = nil
    }

    func performSelectedTranscription() async {
        guard !isTranscribing, !isDiarizing, let recording = selectedRecording else { return }
        let recordingID = recording.id
        isTranscribing = true
        transcriptionRecordingID = recordingID
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        transcriptionProgress = .init(stage: .preparingModel, fractionCompleted: 0)
        defer {
            isTranscribing = false
            if transcriptionRecordingID == recordingID {
                transcriptionRecordingID = nil
            }
            transcriptionProgress = nil
            transcriptionTask = nil
        }

        do {
            let activeRecordingStore = try resolveStore()
            _ = try await persistProcessingState(.processing, recordingID: recordingID)

            let activeTranscriber = try resolveTranscriber()
            let generated = try await activeTranscriber.transcribe(
                recording: recording,
                store: activeRecordingStore,
                progress: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.transcriptionRecordingID == recordingID else { return }
                        self.transcriptionProgress = snapshot
                    }
                }
            )
            try Task.checkCancellation()

            transcriptionProgress = .init(stage: .saving, fractionCompleted: 0)
            let activeTranscriptStore = try resolveTranscriptStore()
            try await activeTranscriptStore.save(generated)

            let state: ProcessingState = generated.metadata.coverage?.completion == .partial ? .partial : .completed
            _ = try await persistProcessingState(state, recordingID: recordingID)
            if selection == recordingID {
                transcript = generated
                if state == .partial {
                    transcriptErrorMessage = "This transcript is partial. Retry transcription to process the full recording."
                }
            }
            transcriptionProgress = .init(stage: .saving, fractionCompleted: 1)
        } catch is CancellationError {
            try? await persistProcessingState(.pending, recordingID: recordingID)
        } catch let partial as PartialTranscriptionFailure {
            if let activeTranscriptStore = try? resolveTranscriptStore() {
                try? await activeTranscriptStore.save(partial.transcript)
            }
            try? await persistProcessingState(.partial, recordingID: recordingID)
            if selection == recordingID {
                transcript = partial.transcript
                transcriptErrorMessage = partial.localizedDescription
            }
        } catch {
            try? await persistProcessingState(.failed, recordingID: recordingID)
            if selection == recordingID {
                transcriptErrorMessage = error.localizedDescription
            }
        }
    }

    func beginDiarization() {
        guard !isTranscribing,
              !isDiarizing,
              let recording = selectedRecording,
              let transcript,
              transcript.isComplete,
              transcript.recordingID == recording.id else {
            return
        }

        diarizationTask = Task { [weak self] in
            await self?.performSelectedDiarization()
        }
    }

    func cancelDiarization() {
        diarizationTask?.cancel()
    }

    func clearDiarizationError() {
        diarizationErrorMessage = nil
    }

    func performSelectedDiarization() async {
        guard !isTranscribing,
              !isDiarizing,
              let recording = selectedRecording,
              let currentTranscript = transcript,
              currentTranscript.isComplete,
              currentTranscript.recordingID == recording.id else {
            return
        }

        let recordingID = recording.id
        isDiarizing = true
        diarizationRecordingID = recordingID
        diarizationErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationProgress = .init(stage: .preparingModel, fractionCompleted: 0)
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
            }
            diarizationProgress = .init(stage: .saving, fractionCompleted: 1)
        } catch is CancellationError {
            // The previously persisted raw/diarized transcript remains authoritative.
        } catch {
            if selection == recordingID {
                diarizationErrorMessage = error.localizedDescription
            }
        }
    }

    func renameSpeaker(_ speakerID: Speaker.ID, to proposedName: String) async {
        guard !isTranscribing,
              !isDiarizing,
              var updated = transcript,
              updated.recordingID == selection else {
            return
        }

        guard let index = updated.speakers.firstIndex(where: { $0.id == speakerID }) else {
            transcriptEditErrorMessage = "That speaker is no longer available in this transcript."
            return
        }

        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        await persistEditedTranscript(updated)
    }

    func updateTranscriptSegment(_ segmentID: TranscriptSegment.ID, text proposedText: String) async {
        guard !isTranscribing,
              !isDiarizing,
              var updated = transcript,
              updated.recordingID == selection else {
            return
        }

        guard let index = updated.segments.firstIndex(where: { $0.id == segmentID }) else {
            transcriptEditErrorMessage = "That transcript segment is no longer available."
            return
        }

        let trimmed = proposedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptEditErrorMessage = "Transcript text cannot be empty."
            return
        }

        let original = updated.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.segments[index].editedText = trimmed == original ? nil : trimmed
        await persistEditedTranscript(updated)
    }

    func restoreOriginalTranscriptSegment(_ segmentID: TranscriptSegment.ID) async {
        guard !isTranscribing,
              !isDiarizing,
              var updated = transcript,
              updated.recordingID == selection else {
            return
        }

        guard let index = updated.segments.firstIndex(where: { $0.id == segmentID }) else {
            transcriptEditErrorMessage = "That transcript segment is no longer available."
            return
        }

        updated.segments[index].editedText = nil
        await persistEditedTranscript(updated)
    }

    func stopPlayback() {
        playback.unload()
    }

    var selectedRecording: Recording? {
        guard let selection else { return nil }
        return recordings.first { $0.id == selection }
    }

    private func cancelProcessingIfNeeded(for recordingID: Recording.ID) async {
        if transcriptionRecordingID == recordingID, let task = transcriptionTask {
            task.cancel()
            await task.value
        }
        if diarizationRecordingID == recordingID, let task = diarizationTask {
            task.cancel()
            await task.value
        }
    }

    @discardableResult
    private func persistProcessingState(
        _ state: ProcessingState,
        recordingID: Recording.ID
    ) async throws -> Recording {
        let activeStore = try resolveStore()
        var current = try await activeStore.read(id: recordingID)
        current.processingState = state
        try await activeStore.update(current)
        replaceRecording(current)
        return current
    }

    private func persistEditedTranscript(_ updated: Transcript) async {
        let recordingID = updated.recordingID
        do {
            try await resolveTranscriptStore().save(updated)
            guard selection == recordingID else { return }
            transcript = updated
            transcriptEditErrorMessage = nil
        } catch {
            guard selection == recordingID else { return }
            transcriptEditErrorMessage = error.localizedDescription
        }
    }

    private func recoverInterruptedTranscriptions(using recordingStore: RecordingStore) async throws {
        guard recordings.contains(where: { $0.processingState == .processing }) else { return }
        let activeTranscriptStore = try resolveTranscriptStore()

        for index in recordings.indices where recordings[index].processingState == .processing {
            var recovered = recordings[index]
            do {
                let persistedTranscript = try await activeTranscriptStore.read(recordingID: recovered.id)
                if let persistedTranscript {
                    recovered.processingState = persistedTranscript.metadata.coverage?.completion == .partial
                        ? .partial
                        : .completed
                } else {
                    recovered.processingState = .failed
                }
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

    private func replaceRecording(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
    }
}
