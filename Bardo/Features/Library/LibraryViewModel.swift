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
    /// When the running transcription's current stage began, so the interface can show
    /// estimates and timed messages that survive leaving the view.
    @Published private(set) var transcriptionStageStartedAt: Date?
    @Published private(set) var diarizationErrorMessage: String?
    @Published private(set) var diarizationProgress: DiarizationProgressSnapshot?
    @Published private(set) var diarizationRecordingID: Recording.ID?
    @Published private(set) var shouldPresentSpeakerNamingSheet = false
    @Published private(set) var searchDocuments: [LibrarySearchDocument] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isDiarizing = false
    /// The recording whose audio is being compressed, one at a time.
    @Published private(set) var compressingRecordingID: Recording.ID?
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

    /// Changes a saved recording's moments and sections.
    func updateNotes(_ recordingID: Recording.ID, _ change: (inout RecordingNotes) -> Void) async {
        do {
            try await updateRecording(recordingID) { change(&$0.notes) }
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    func setSkipsSilences(_ recordingID: Recording.ID, _ skips: Bool) async {
        do {
            try await updateRecording(recordingID) { $0.skipsSilences = skips }
            await applySilenceSkipping()
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    /// Re-encodes a recording's audio at a lower quality to take less space. A track is
    /// replaced only when its new file is smaller; the rest stay as they are.
    func compressAudio(_ recordingID: Recording.ID, to preset: AudioQualityPreset) async {
        guard compressingRecordingID == nil, !isProcessing(recordingID),
              let recording = recordings.first(where: { $0.id == recordingID }) else { return }
        compressingRecordingID = recordingID
        defer { compressingRecordingID = nil }

        let encoding = AudioEncoding(preset: preset, format: .aac)
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bardo-compress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        do {
            let store = try resolveStore()
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            var replacements: [(asset: AudioAsset, sourceURL: URL)] = []
            for asset in recording.audioAssets {
                let source = try await store.managedAudioURL(recordingID: recordingID, audioAssetID: asset.id)
                let destination = workDirectory.appendingPathComponent("\(asset.id.uuidString).m4a")
                try await AudioFileTranscoder().transcode(from: source, to: destination, encoding: encoding)
                guard Self.fileSize(destination) < Self.fileSize(source) else { continue }
                let name = (asset.originalFileName as NSString).deletingPathExtension
                replacements.append((
                    AudioAsset(
                        id: asset.id,
                        originalFileName: "\(name).m4a",
                        fileExtension: "m4a",
                        metadata: try AudioMetadataReader().read(from: destination),
                        role: asset.role,
                        timelineOffset: asset.timelineOffset,
                        derivedFromAssetIDs: asset.derivedFromAssetIDs
                    ),
                    destination
                ))
            }
            guard !replacements.isEmpty else { return }

            // The player lets go of the old files while they are swapped.
            let isSelected = selection == recordingID
            if isSelected { playback.unload() }
            let updated = try await store.replaceAudio(of: recordingID, with: replacements)
            if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
                recordings[index].audioAssets = updated.audioAssets
            }
            if isSelected { await preparePlaybackForSelection() }
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
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

    /// Shows the item behind a Library issue in Finder.
    func revealIssue(_ issue: RecordingStoreIssue) async {
        guard let url = try? await resolveStore().itemURL(for: issue) else {
            recordingActionErrorMessage = String(localized: "That item is no longer in the Library.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Moves the items behind the given Library issues to the macOS Trash and reloads.
    func moveIssuesToTrash(_ selected: [RecordingStoreIssue]) async {
        do {
            let activeStore = try resolveStore()
            for issue in selected where issue.canMoveToTrash {
                try await activeStore.moveIssueItemToTrash(issue)
            }
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
        await reload()
    }

    func managedLocation(for recordingID: Recording.ID) async throws -> URL {
        try await resolveStore().recordingDirectoryURL(recordingID: recordingID)
    }

    func managedAudioURL(for asset: AudioAsset, in recordingID: Recording.ID) async throws -> URL {
        try await resolveStore().managedAudioURL(recordingID: recordingID, audioAssetID: asset.id)
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
        await applySilenceSkipping()
    }

    /// Long silences of each recording, found once and kept for the session.
    private var silentRanges: [Recording.ID: [ClosedRange<TimeInterval>]] = [:]

    /// Has the player jump over long silences when the selected recording asks for it.
    func applySilenceSkipping() async {
        guard let recording = selectedRecording, recording.skipsSilences else {
            playback.skippedRanges = []
            return
        }
        if let ranges = silentRanges[recording.id] {
            playback.skippedRanges = ranges
            return
        }
        let tracks = playback.loadedTracks
        let ranges = await Task.detached(priority: .utility) {
            (try? AudioWaveformOverview.silentRanges(of: tracks)) ?? []
        }.value
        guard selection == recording.id else { return }
        silentRanges[recording.id] = ranges
        playback.skippedRanges = ranges
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

        // A recording with both originals plays them as separate tracks, so either
        // voice can be heard alone; the mix remains the fallback.
        if let tracks = TranscriptionAudioSelection.separateTracks(for: recording, mode: .perTrack),
           let activeStore = try? resolveStore(),
           let systemURL = try? await activeStore.managedAudioURL(recordingID: recordingID, audioAssetID: tracks.system.id),
           let microphoneURL = try? await activeStore.managedAudioURL(recordingID: recordingID, audioAssetID: tracks.microphone.id) {
            guard selection == recordingID else { return false }
            let loaded = controller.load(
                tracks: [
                    PlaybackTrack(url: microphoneURL, offset: tracks.microphone.timelineOffset, source: .microphone),
                    PlaybackTrack(url: systemURL, offset: tracks.system.timelineOffset, source: .system)
                ],
                metadata: AudioPlaybackMetadata(title: recording.title, trackLabel: String(localized: "Separate tracks"))
            )
            if loaded { return true }
            lastError = controller.errorMessage
        }

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
        // Live text belongs to the running job; keep it while the person looks at other
        // conversations so coming back shows everything recognized so far.
        if liveTranscription?.recordingID != transcriptionRecordingID {
            liveTranscription = nil
        }
        guard let recordingID = selection else {
            transcript = nil
            return
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

    /// Starts transcribing the selection. `trackMode` overrides the Settings choice for
    /// a recording with a microphone and Mac audio track.
    func beginTranscription(trackMode: TranscriptionTrackMode? = nil) {
        guard let recording = startTranscriptionIfPossible() else { return }
        let mode = trackMode ?? .preferred
        transcriptionTask = Task { [weak self] in
            await self?.runTranscription(of: recording, trackMode: mode)
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

    func performSelectedTranscription(trackMode: TranscriptionTrackMode = .preferred) async {
        guard let recording = startTranscriptionIfPossible() else { return }
        await runTranscription(of: recording, trackMode: trackMode)
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
        transcriptionStageStartedAt = .now
        liveTranscription = .empty(recordingID: recording.id, audioDuration: recording.duration ?? 0)
        return recording
    }

    private func setTranscriptionProgress(_ snapshot: TranscriptionProgressSnapshot) {
        if transcriptionProgress?.stage != snapshot.stage {
            transcriptionStageStartedAt = .now
        }
        transcriptionProgress = snapshot
    }

    private func runTranscription(of startingRecording: Recording, trackMode: TranscriptionTrackMode) async {
        var recording = startingRecording
        let recordingID = recording.id
        defer {
            isTranscribing = false
            transcriptionRecordingID = nil
            transcriptionProgress = nil
            transcriptionStageStartedAt = nil
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
                trackMode: trackMode,
                progress: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.transcriptionRecordingID == recordingID else { return }
                        self.setTranscriptionProgress(snapshot)
                    }
                },
                liveUpdate: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self,
                              self.transcriptionRecordingID == recordingID,
                              snapshot.recordingID == recordingID else {
                            return
                        }
                        self.liveTranscription = snapshot
                    }
                }
            )
            try Task.checkCancellation()

            setTranscriptionProgress(.init(stage: .saving, fractionCompleted: 0))
            let activeTranscriptStore = try resolveTranscriptStore()
            try await activeTranscriptStore.save(generated)

            try await updateRecording(recordingID) { $0.processingState = .completed }
            // The models may have been downloaded on demand for this transcription.
            NotificationCenter.default.post(name: .bardoModelsChanged, object: nil)
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
            NotificationCenter.default.post(name: .bardoModelsChanged, object: nil)
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
        await saveSpeakerReview(names: [:], merges: [(sourceID, targetID)])
    }

    /// Saves the speaker review at once: participants merged into one, in the order they
    /// were merged, then the names typed.
    func saveSpeakerReview(names: [Speaker.ID: String], merges: [(source: Speaker.ID, target: Speaker.ID)]) async {
        guard var updated = transcript,
              updated.recordingID == selection,
              canEditTranscript(of: updated.recordingID) else {
            return
        }
        for merge in merges {
            updated = updated.mergingSpeaker(merge.source, into: merge.target)
        }
        for index in updated.speakers.indices {
            guard let proposed = names[updated.speakers[index].id] else { continue }
            updated.speakers[index].name = proposed.nonEmptyTrimmed
        }
        guard updated != transcript else { return }
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

            let names: [String] = loadedTranscript.map { transcript in
                transcript.speakers.map { transcript.displayName(for: $0) }
            } ?? []

            documents.append(
                LibrarySearchDocument(
                    id: recording.id,
                    title: LibraryFormatting.recordingTitle(recording),
                    createdAt: recording.createdAt,
                    duration: recording.duration,
                    source: LibraryFormatting.source(recording.sources),
                    participantNames: names,
                    // The microphone speaker counts as named once the person set their name.
                    namedParticipants: loadedTranscript?.speakers.compactMap { speaker in
                        speaker.name?.nonEmptyTrimmed
                            ?? (speaker.role == .localUser ? LocalSpeakerName.current : nil)
                    } ?? [],
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
