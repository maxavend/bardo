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
    @Published private(set) var meetingMinutes: MeetingMinutes?
    @Published private(set) var meetingMinutesIsStale = false
    @Published private(set) var meetingMinutesErrorMessage: String?
    @Published private(set) var meetingMinutesProgress: Double?
    @Published private(set) var meetingMinutesProgressSnapshot: MeetingMinutesProgressSnapshot?
    @Published private(set) var streamingMeetingMinutesText: String?
    @Published private(set) var isGeneratingMeetingMinutes = false
    @Published private(set) var shouldPresentSpeakerNamingSheet = false
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isDiarizing = false
    @Published var selection: Recording.ID?

    let playback: AudioPlaybackController

    private var store: RecordingStore?
    private var importer: AudioImportService?
    private var transcriptStore: TranscriptStore?
    private var meetingMinutesStore: MeetingMinutesStore?
    private var transcriber: (any RecordingTranscribing)?
    private var diarizer: (any RecordingDiarizing)?
    private var meetingMinutesGenerator: (any MeetingMinutesGenerating)?
    private var transcriptionTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var meetingMinutesTask: Task<Void, Never>?

    init(
        store: RecordingStore? = nil,
        importer: AudioImportService? = nil,
        playback: AudioPlaybackController? = nil,
        transcriptStore: TranscriptStore? = nil,
        transcriber: (any RecordingTranscribing)? = nil,
        diarizer: (any RecordingDiarizing)? = nil,
        meetingMinutesStore: MeetingMinutesStore? = nil,
        meetingMinutesGenerator: (any MeetingMinutesGenerating)? = nil
    ) {
        self.store = store
        self.importer = importer
        self.playback = playback ?? AudioPlaybackController()
        self.transcriptStore = transcriptStore
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.meetingMinutesStore = meetingMinutesStore
        self.meetingMinutesGenerator = meetingMinutesGenerator
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

    func renameRecording(_ recordingID: Recording.ID, to proposedTitle: String) async {
        guard var recording = recordings.first(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = "That recording is no longer available."
            return
        }

        guard !isTranscribing, !isDiarizing else {
            recordingActionErrorMessage = "Finish or cancel processing before renaming this recording."
            return
        }

        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            recordingActionErrorMessage = "Recording title cannot be empty."
            recordingActionFeedback = nil
            return
        }

        recordingActionErrorMessage = nil
        recordingActionFeedback = nil
        recording.title = title

        do {
            try await resolveStore().update(recording)
            replaceRecording(recording)
            recordingActionFeedback = "Recording renamed"
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    func deleteRecording(_ recordingID: Recording.ID) async {
        guard recordings.contains(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = "That recording is no longer available."
            return
        }

        guard recordingID != transcriptionRecordingID,
              recordingID != diarizationRecordingID,
              !(isDiarizing && selection == recordingID),
              !(isGeneratingMeetingMinutes && selection == recordingID)
        else {
            recordingActionErrorMessage = "Finish or cancel processing before deleting this recording."
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
                meetingMinutes = nil
                meetingMinutesIsStale = false
                playback.unload()
            }
            recordingActionFeedback = "Recording moved to the Trash"
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    func managedLocation(for recordingID: Recording.ID) async throws -> URL {
        try await resolveStore().recordingDirectoryURL(recordingID: recordingID)
    }

    func playRecording(_ recordingID: Recording.ID) async {
        guard recordings.contains(where: { $0.id == recordingID }) else {
            recordingActionErrorMessage = "That recording is no longer available."
            return
        }

        if selection != recordingID {
            selection = recordingID
            await preparePlaybackForSelection()
        }

        guard selection == recordingID else { return }
        guard playback.isLoaded else {
            recordingActionErrorMessage = playback.errorMessage ?? "This recording has no playable managed audio."
            return
        }
        _ = playback.play()
    }

    func copyManagedLocation(_ recordingID: Recording.ID) async {
        do {
            let location = try await managedLocation(for: recordingID)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(location.path, forType: .string) else {
                recordingActionErrorMessage = "Bardo could not copy the managed location to the clipboard."
                recordingActionFeedback = nil
                return
            }
            recordingActionErrorMessage = nil
            recordingActionFeedback = "Managed location copied"
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

        // Keep the current player geometry/state alive while the new managed URL
        // resolves. Unloading here made toolbar/sidebar clicks visibly disable and
        // rebuild the player before the replacement audio was ready.
        if playback.isPlaying {
            playback.pause()
        }

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

        controller.setUnavailable(lastError ?? "This recording has no playable managed audio.")
        return false
    }

    func loadTranscriptForSelection() async {
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        meetingMinutesErrorMessage = nil
        if !isGeneratingMeetingMinutes {
            streamingMeetingMinutesText = nil
            meetingMinutesProgressSnapshot = nil
        }
        guard let recordingID = selection else {
            transcript = nil
            meetingMinutes = nil
            meetingMinutesIsStale = false
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

            if let loaded {
                meetingMinutes = try await resolveMeetingMinutesStore().read(recordingID: loaded.recordingID)
                meetingMinutesIsStale = meetingMinutes?.isStale(comparedTo: loaded) ?? false
            } else {
                meetingMinutes = nil
                meetingMinutesIsStale = false
            }

            if loaded == nil {
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
        guard !isTranscribing, !isDiarizing, var recording = selectedRecording else { return }
        let recordingID = recording.id
        isTranscribing = true
        transcriptionRecordingID = recordingID
        transcriptErrorMessage = nil
        transcriptEditErrorMessage = nil
        diarizationErrorMessage = nil
        transcriptionProgress = .init(stage: .preparingModel, fractionCompleted: 0)
        liveTranscription = .empty(recordingID: recordingID, audioDuration: recording.duration ?? 0)
        defer {
            isTranscribing = false
            transcriptionRecordingID = nil
            transcriptionProgress = nil
            liveTranscription = nil
            transcriptionTask = nil
        }

        do {
            let activeRecordingStore = try resolveStore()
            recording.processingState = .processing
            try await activeRecordingStore.update(recording)
            replaceRecording(recording)

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

            recording.processingState = .completed
            try await activeRecordingStore.update(recording)
            replaceRecording(recording)
            if selection == recordingID {
                transcript = generated
                liveTranscription = nil
                meetingMinutesIsStale = meetingMinutes?.isStale(comparedTo: generated) ?? false
            }
            transcriptionProgress = .init(stage: .saving, fractionCompleted: 1)
        } catch is CancellationError {
            recording.processingState = .pending
            if let activeStore = try? resolveStore() {
                try? await activeStore.update(recording)
            }
            replaceRecording(recording)
        } catch {
            recording.processingState = .failed
            if let activeStore = try? resolveStore() {
                try? await activeStore.update(recording)
            }
            replaceRecording(recording)
            transcriptErrorMessage = error.localizedDescription
        }
    }

    func beginDiarization() {
        guard !isTranscribing,
              !isDiarizing,
              let recording = selectedRecording,
              let transcript,
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

    func consumeSpeakerNamingSheetRequest() {
        shouldPresentSpeakerNamingSheet = false
    }

    func performSelectedDiarization() async {
        guard !isTranscribing,
              !isDiarizing,
              let recording = selectedRecording,
              let currentTranscript = transcript,
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
                meetingMinutesIsStale = meetingMinutes?.isStale(comparedTo: updated) ?? false

                // Speaker identification must never leave the document player unusable.
                // If playback was unavailable before or during diarization, restore it
                // from the authoritative managed recording before presenting naming.
                if !playback.isLoaded {
                    _ = await preparePlayback(playback, for: recording)
                }

                if SpeakerNamingPolicy.shouldOpenNamingFlow(after: updated) {
                    shouldPresentSpeakerNamingSheet = true
                }
            }
            diarizationProgress = .init(stage: .saving, fractionCompleted: 1)
        } catch is CancellationError {
            // The previously persisted raw/diarized transcript remains authoritative.
        } catch {
            diarizationErrorMessage = error.localizedDescription
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

    func renameSpeakers(_ proposedNames: [Speaker.ID: String]) async {
        guard !isTranscribing,
              !isDiarizing,
              var updated = transcript,
              updated.recordingID == selection else {
            return
        }

        for (speakerID, proposedName) in proposedNames {
            guard let index = updated.speakers.firstIndex(where: { $0.id == speakerID }) else {
                transcriptEditErrorMessage = "That speaker is no longer available in this transcript."
                return
            }
            let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        }
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

    var hasActiveMeetingMinutesTask: Bool {
        meetingMinutesTask != nil
    }

    var canGenerateMeetingMinutes: Bool {
        guard let recording = selectedRecording,
              let transcript,
              transcript.recordingID == recording.id,
              !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return !isTranscribing && !isDiarizing && !isGeneratingMeetingMinutes
    }

    func beginMeetingMinutes() {
        guard canGenerateMeetingMinutes else { return }
        isGeneratingMeetingMinutes = true
        meetingMinutesErrorMessage = nil
        meetingMinutesProgress = 0
        meetingMinutesProgressSnapshot = MeetingMinutesProgressSnapshot(
            stage: .preparingModel,
            fractionCompleted: 0,
            message: String(localized: "Preparing meeting-minutes model in local memory…")
        )
        streamingMeetingMinutesText = ""
        meetingMinutesTask = Task { [weak self] in
            await self?.performMeetingMinutes()
        }
    }

    func cancelMeetingMinutes() {
        meetingMinutesTask?.cancel()
        streamingMeetingMinutesText = nil
        meetingMinutesProgressSnapshot = nil
    }

    func clearMeetingMinutesError() {
        meetingMinutesErrorMessage = nil
    }

    func performMeetingMinutes(title: String? = nil, context: String? = nil) async {
        defer {
            isGeneratingMeetingMinutes = false
            meetingMinutesProgress = nil
            meetingMinutesProgressSnapshot = nil
            meetingMinutesTask = nil
        }

        guard let transcript,
              let recording = selectedRecording,
              transcript.recordingID == recording.id,
              !Task.isCancelled else { return }

        do {
            playback.unload()
            let generator = try resolveMeetingMinutesGenerator()
            do {
                let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedContext = context?.trimmingCharacters(in: .whitespacesAndNewlines)
                let generated = try await generator.generate(
                    from: MeetingMinutesInput(
                        transcript: transcript,
                        title: resolvedTitle?.isEmpty == false ? resolvedTitle! : recording.title,
                        context: resolvedContext?.isEmpty == false ? resolvedContext : nil
                    ),
                    progress: { [weak self] snapshot in
                        Task { @MainActor in
                            guard let self, self.selection == recording.id else { return }
                            self.meetingMinutesProgress = min(1, max(0, snapshot.fractionCompleted))
                            self.meetingMinutesProgressSnapshot = snapshot
                        }
                    },
                    onStreamChunk: { [weak self] chunk in
                        Task { @MainActor in
                            guard let self, self.selection == recording.id else { return }
                            self.streamingMeetingMinutesText = (self.streamingMeetingMinutesText ?? "") + chunk
                        }
                    }
                )
                try Task.checkCancellation()
                try await resolveMeetingMinutesStore().save(generated)
                guard selection == recording.id else { return }
                meetingMinutes = generated
                streamingMeetingMinutesText = nil
                meetingMinutesProgress = 1
            } catch {
                await generator.reset()
                throw error
            }
        } catch is CancellationError {
            // Cancellation leaves the last persisted minutes intact.
            if selection == recording.id {
                streamingMeetingMinutesText = nil
            }
        } catch {
            if selection == recording.id {
                streamingMeetingMinutesText = nil
            }
            meetingMinutesErrorMessage = error.localizedDescription
        }
    }

    var selectedRecording: Recording? {
        guard let selection else { return nil }
        return recordings.first { $0.id == selection }
    }

    private func persistEditedTranscript(_ updated: Transcript) async {
        let recordingID = updated.recordingID
        do {
            try await resolveTranscriptStore().save(updated)
            guard selection == recordingID else { return }
            transcript = updated
            meetingMinutesIsStale = meetingMinutes?.isStale(comparedTo: updated) ?? false
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
                recovered.processingState = persistedTranscript == nil ? .failed : .completed
            } catch {
                // A corrupt or incomplete transcript cannot be trusted as completed. Preserve it
                // on disk and make the Recording retryable rather than leaving it stuck forever.
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

    private func resolveMeetingMinutesStore() throws -> MeetingMinutesStore {
        if let meetingMinutesStore {
            return meetingMinutesStore
        }
        let store = try MeetingMinutesStore.live()
        meetingMinutesStore = store
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

    private func resolveMeetingMinutesGenerator() throws -> any MeetingMinutesGenerating {
        if let meetingMinutesGenerator {
            return meetingMinutesGenerator
        }
        let generator = try MeetingMinutesGenerator.live()
        meetingMinutesGenerator = generator
        return generator
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
