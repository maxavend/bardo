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
    @Published private(set) var transcript: Transcript? {
        didSet {
            // Merging or identifying participants changes whose turns are whose.
            if oldValue?.speakers != transcript?.speakers, !listenedSpeakers.isEmpty {
                Task { await applySkipping() }
            }
        }
    }
    /// Whom playback lets through, per recording, while Bardo is open; everyone when
    /// a recording has no entry.
    @Published private(set) var listenedSpeakers: [Recording.ID: Set<Speaker.ID>] = [:]
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
    /// The compression in progress or just finished, for its sheet.
    @Published private(set) var compressionRun: AudioCompressionRun?
    /// A manual edit is being written; model work must not start from a stale copy.
    @Published private(set) var isSavingTranscriptEdit = false
    /// The conversations selected in the list; several when a person ⌘- or ⇧-clicks.
    @Published var selectedIDs: Set<Recording.ID> = []

    /// The one conversation open in the detail column; `nil` when none or several are
    /// selected.
    var selection: Recording.ID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }

    let playback: AudioPlaybackController

    private var store: RecordingStore?
    private var importer: AudioImportService?
    private var transcriptStore: TranscriptStore?
    private var transcriber: (any RecordingTranscribing)?
    private var diarizer: (any RecordingDiarizing)?
    private var transcriptionTask: Task<Void, Never>?
    private var stopsCompression = false
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

    /// Moves recordings to Archivadas, or back to the Library's lists. Nothing is
    /// deleted; the change is saved in each recording's manifest.
    func setArchived(_ recordingIDs: Set<Recording.ID>, _ archived: Bool) async {
        recordingActionErrorMessage = nil
        for recording in recordings where recordingIDs.contains(recording.id) && recording.isArchived != archived {
            do {
                try await updateRecording(recording.id) { $0.isArchived = archived }
            } catch {
                recordingActionErrorMessage = error.localizedDescription
            }
        }
    }

    func setSkipsSilences(_ recordingID: Recording.ID, _ skips: Bool) async {
        do {
            try await updateRecording(recordingID) { $0.skipsSilences = skips }
            await applySkipping()
        } catch {
            recordingActionErrorMessage = error.localizedDescription
        }
    }

    /// Re-encodes conversations' audio at a lower quality to take less space, one after
    /// another. A track is replaced only when its new file is smaller; the rest stay as
    /// they are. `stopCompression()` lets the conversation in progress finish first.
    func compressAudio(
        _ recordingIDs: [Recording.ID],
        using encoding: AudioCompressionEncoding,
        copyTo folder: URL? = nil,
        mergeTracks: Bool = false
    ) async {
        guard compressionRun?.isRunning != true else { return }
        let ids = recordingIDs.filter { id in
            recordings.contains { $0.id == id && !$0.audioAssets.isEmpty }
        }
        guard !ids.isEmpty else { return }

        stopsCompression = false
        var run = AudioCompressionRun(total: ids.count, copyFolder: folder)
        compressionRun = run
        defer {
            compressingRecordingID = nil
            run.isRunning = false
            run.currentTitle = nil
            compressionRun = run
        }

        for id in ids {
            guard !stopsCompression else { break }
            guard let recording = recordings.first(where: { $0.id == id }) else { continue }
            run.currentTitle = LibraryFormatting.recordingTitle(recording)
            run.phase = .preparing
            compressionRun = run
            if isProcessing(id) {
                run.failures.append(.init(
                    title: LibraryFormatting.recordingTitle(recording),
                    reason: "Se está transcribiendo."
                ))
            } else {
                compressingRecordingID = id
                do {
                    let result = try await compressAudio(of: recording, encoding: encoding, copyTo: folder, mergeTracks: mergeTracks)
                    if let copyURL = result.copyURL {
                        run.copyURLs.append(copyURL)
                        run.copiedBytes += result.bytes
                    } else {
                        run.savedBytes += result.bytes
                    }
                } catch {
                    run.failures.append(.init(
                        title: LibraryFormatting.recordingTitle(recording),
                        reason: error.localizedDescription
                    ))
                }
            }
            run.completed += 1
            run.stoppingAfterCurrent = stopsCompression
            compressionRun = run
        }
        run.wasStopped = stopsCompression && run.completed < run.total
    }

    /// Lets the conversation being compressed finish, then stops.
    func stopCompression() {
        stopsCompression = true
        compressionRun?.stoppingAfterCurrent = true
    }

    /// Forgets a finished compression, once its result has been seen.
    func clearCompressionRun() {
        guard compressionRun?.isRunning != true else { return }
        compressionRun = nil
    }

    /// A copy is published as one folder after every track has been encoded.
    private func compressAudio(
        of recording: Recording,
        encoding: AudioCompressionEncoding,
        copyTo folder: URL?,
        mergeTracks: Bool
    ) async throws -> (bytes: Int64, copyURL: URL?) {
        let recordingID = recording.id
        let manager = FileManager.default
        let workDirectory = (folder ?? manager.temporaryDirectory)
            .appendingPathComponent(".bardo-compress-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: workDirectory) }

        let store = try resolveStore()
        if mergeTracks, let mix = AudioCompressionMix(recording: recording) {
            return try await compressMix(mix, recording: recording, store: store,
                                         encoding: encoding, workDirectory: workDirectory, copyTo: folder)
        }
        var tracks: [(asset: AudioAsset, source: URL, originalBytes: Int64?, duration: TimeInterval)] = []
        for asset in recording.audioAssets {
            let source = try await store.managedAudioURL(recordingID: recordingID, audioAssetID: asset.id)
            let before = LibraryStorage.fileSize(source)
            if folder == nil {
                let estimated = AudioCompressionPlan.compressedBytes(of: asset, encoding: encoding)
                guard let before, Double(estimated) < Double(before) * AudioCompressionPlan.worthwhileShare else {
                    continue
                }
            }
            let duration = asset.metadata.duration.isFinite ? max(0, asset.metadata.duration) : 0
            tracks.append((asset, source, before, duration))
        }
        guard !tracks.isEmpty else { return (0, nil) }

        try manager.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        var replacements: [(asset: AudioAsset, sourceURL: URL)] = []
        var saved: Int64 = 0
        var copied: Int64 = 0
        let fileExtension = encoding.format.fileExtension
        let recordingDuration = tracks.reduce(0) { $0 + $1.duration }
        var precedingDuration: TimeInterval = 0
        for (index, track) in tracks.enumerated() {
            let asset = track.asset
            let name = ((asset.originalFileName as NSString).lastPathComponent as NSString).deletingPathExtension
            let baseName = folder == nil ? asset.id.uuidString : name
            let destination = Self.availableCopyURL(in: workDirectory, name: baseName, fileExtension: fileExtension)
            let progress = AudioCompressionRun.TrackProgress(
                title: LibraryFormatting.audioTrackTitle(asset),
                number: index + 1,
                count: tracks.count,
                duration: track.duration,
                precedingDuration: precedingDuration,
                recordingDuration: recordingDuration
            )
            try await encodeCompression(input: .file(track.source, duration: track.duration),
                                        to: destination, using: encoding, progress: progress)
            precedingDuration += track.duration
            guard let after = LibraryStorage.fileSize(destination) else {
                throw CocoaError(.fileReadUnknown)
            }
            if folder != nil {
                copied += after
                continue
            }
            // Re-encoding lossy audio costs quality: only worth it for a real saving,
            // the same rule the estimate shown before compressing follows.
            guard let before = track.originalBytes,
                  Double(after) < Double(before) * AudioCompressionPlan.worthwhileShare else { continue }
            let metadata = try AudioMetadataReader().read(from: destination, verifySamples: true)
            guard metadata.channelCount == UInt32(encoding.channels.rawValue) else {
                throw AudioTranscodingError.couldNotConvert
            }
            guard metadata.duration >= asset.metadata.duration - 0.25 else {
                throw AudioTranscodingError.incompleteOutput(
                    expected: asset.metadata.duration,
                    actual: metadata.duration
                )
            }
            saved += before - after
            replacements.append((
                AudioAsset(
                    id: asset.id,
                    originalFileName: "\(name).\(fileExtension)",
                    fileExtension: fileExtension,
                    metadata: metadata,
                    role: asset.role,
                    timelineOffset: asset.timelineOffset,
                    derivedFromAssetIDs: asset.derivedFromAssetIDs
                ),
                destination
            ))
        }
        if let folder, copied > 0 {
            return (copied, try publishCompressionCopy(workDirectory, recording: recording, encoding: encoding, to: folder))
        }
        guard !replacements.isEmpty else { return (0, nil) }
        try await publishCompressedAudio(for: recordingID) {
            try await store.replaceAudio(of: recordingID, with: replacements)
        }
        return (saved, nil)
    }

    private func compressMix(
        _ mix: AudioCompressionMix,
        recording: Recording,
        store: RecordingStore,
        encoding: AudioCompressionEncoding,
        workDirectory: URL,
        copyTo folder: URL?
    ) async throws -> (bytes: Int64, copyURL: URL?) {
        var before: Int64 = 0
        if folder == nil {
            for asset in recording.audioAssets {
                if let url = try? await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id),
                   let bytes = LibraryStorage.fileSize(url) {
                    before += bytes
                }
            }
            let estimate = AudioCompressionPlan.compressedBytes(duration: mix.duration, encoding: encoding)
            guard Double(estimate) < Double(before) * AudioCompressionPlan.worthwhileShare else { return (0, nil) }
        }

        let input = try await compressionInput(for: recording, mix: mix, store: store)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        let fileExtension = encoding.format.fileExtension
        let output = workDirectory.appendingPathComponent("Pista unificada").appendingPathExtension(fileExtension)
        try await encodeCompression(
            input: input, to: output, using: encoding,
            progress: .init(title: "Pista unificada", number: 1, count: 1, duration: mix.duration,
                            precedingDuration: 0, recordingDuration: mix.duration)
        )
        guard let after = LibraryStorage.fileSize(output) else { throw CocoaError(.fileReadUnknown) }
        let metadata = try AudioMetadataReader().read(from: output, verifySamples: true)
        guard metadata.channelCount == UInt32(encoding.channels.rawValue) else {
            throw AudioTranscodingError.couldNotConvert
        }
        guard metadata.duration >= mix.duration - 0.25 else {
            throw AudioTranscodingError.incompleteOutput(expected: mix.duration, actual: metadata.duration)
        }
        if let folder {
            return (after, try publishCompressionCopy(workDirectory, recording: recording, encoding: encoding, to: folder))
        }
        guard Double(after) < Double(before) * AudioCompressionPlan.worthwhileShare else { return (0, nil) }

        let asset = AudioAsset(
            originalFileName: output.lastPathComponent, fileExtension: fileExtension,
            metadata: metadata, role: .conversationMix,
            derivedFromAssetIDs: mix.existing?.derivedFromAssetIDs ?? mix.originals.map(\.id)
        )
        try await publishCompressedAudio(for: recording.id) {
            try await store.replaceAllAudio(
                of: recording.id, expectedAssetIDs: Set(recording.audioAssets.map(\.id)), with: asset, from: output
            )
        }
        return (before - after, nil)
    }

    private func publishCompressedAudio(
        for recordingID: Recording.ID, using publish: () async throws -> Recording
    ) async throws {
        // The player lets go of the old files while they are swapped.
        compressionRun?.phase = .saving
        let isSelected = selection == recordingID
        if isSelected { playback.unload() }
        do {
            let updated = try await publish()
            if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
                recordings[index].audioAssets = updated.audioAssets
            }
            silentRanges[recordingID] = nil
        } catch {
            if isSelected, selection == recordingID { await preparePlaybackForSelection() }
            throw error
        }
        if isSelected, selection == recordingID {
            compressionRun?.phase = .preparingPlayback
            await preparePlaybackForSelection()
        }
    }

    func compressionPreviewInput(for recording: Recording, mergeTracks: Bool) async throws -> AudioCompressionInput {
        let store = try resolveStore()
        if mergeTracks, let mix = AudioCompressionMix(recording: recording) {
            return try await compressionInput(for: recording, mix: mix, store: store)
        }
        guard let asset = recording.playbackAudioAssets.first else { throw AudioTranscodingError.couldNotConvert }
        let url = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
        return .file(url, duration: asset.metadata.duration)
    }

    private func compressionInput(
        for recording: Recording, mix: AudioCompressionMix, store: RecordingStore
    ) async throws -> AudioCompressionInput {
        if let asset = mix.existing,
           let url = try? await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id),
           let metadata = try? AudioMetadataReader().read(from: url, verifySamples: true),
           metadata.duration >= mix.duration - 0.25 {
            return .file(url, duration: metadata.duration)
        }
        if let existing = mix.existing,
           !Set(existing.derivedFromAssetIDs).isSubset(of: Set(mix.originals.map(\.id))) {
            throw AudioTranscodingError.couldNotConvert
        }
        var tracks: [AudioCompressionInput.Track] = []
        for asset in mix.originals {
            let url = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
            tracks.append(.init(url: url, offset: asset.timelineOffset, duration: asset.metadata.duration))
        }
        if tracks.count == 1, let track = tracks.first, track.offset == 0 {
            return .file(track.url, duration: track.duration)
        }
        return .mix(tracks, duration: mix.duration)
    }

    private func publishCompressionCopy(
        _ workDirectory: URL, recording: Recording, encoding: AudioCompressionEncoding, to folder: URL
    ) throws -> URL {
        compressionRun?.phase = .saving
        let title = LibraryFormatting.recordingTitle(recording).prefix(31)
        let name = "\(title) – \(encoding.format.rawValue) \(encoding.bitRate.rawValue) \(encoding.channels.title)"
        let destination = Self.availableCopyURL(in: folder, name: name)
        try FileManager.default.moveItem(at: workDirectory, to: destination)
        return destination
    }

    private func encodeCompression(
        input: AudioCompressionInput, to destination: URL,
        using encoding: AudioCompressionEncoding, progress: AudioCompressionRun.TrackProgress
    ) async throws {
        compressionRun?.phase = .encoding(progress)
        try await AudioCompressionTranscoder.encode(input: input, to: destination, using: encoding) { [weak self] seconds in
            Task { @MainActor [weak self] in
                self?.updateCompressionProgress(trackID: progress.id, processed: seconds)
            }
        }
    }

    private func updateCompressionProgress(trackID: UUID, processed: TimeInterval) {
        guard compressionRun?.isRunning == true,
              case .encoding(var track) = compressionRun?.phase,
              track.id == trackID else { return }
        let clamped = min(processed, track.duration)
        guard clamped > track.processed else { return }
        track.processed = clamped
        compressionRun?.phase = .encoding(track)
    }

    private static func availableCopyURL(in folder: URL, name: String, fileExtension: String? = nil) -> URL {
        let safeName = String(name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .prefix(55))
        let base = safeName.isEmpty ? "Audio" : safeName
        func url(_ name: String) -> URL {
            let candidate = folder.appendingPathComponent(name, isDirectory: fileExtension == nil)
            return fileExtension.map { candidate.appendingPathExtension($0) } ?? candidate
        }
        var candidate = url(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// How much space each conversation takes, measured away from the main thread.
    /// With `ids`, only those conversations are measured; otherwise every one, the
    /// Library folder, the models and the free space as well.
    func storageReport(for ids: Set<Recording.ID>? = nil) async -> LibraryStorageReport {
        guard let store = try? resolveStore() else { return .empty }
        var locations: [(id: Recording.ID, directory: URL, audio: [(AudioAsset.ID, URL)])] = []
        for recording in recordings where ids?.contains(recording.id) ?? true {
            guard let directory = try? await store.recordingDirectoryURL(recordingID: recording.id) else { continue }
            var audio: [(AudioAsset.ID, URL)] = []
            for asset in recording.audioAssets {
                if let url = try? await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id) {
                    audio.append((asset.id, url))
                }
            }
            locations.append((recording.id, directory, audio))
        }
        let libraryURL = ids == nil ? try? RecordingStore.defaultLibraryURL() : nil
        let measuresEverything = ids == nil
        let measured = locations
        return await Task.detached(priority: .userInitiated) {
            var report = LibraryStorageReport()
            for location in measured {
                var audioBytes: [AudioAsset.ID: Int64] = [:]
                for (id, url) in location.audio {
                    if let size = LibraryStorage.fileSize(url) { audioBytes[id] = size }
                }
                report.entries[location.id] = .init(
                    totalBytes: LibraryStorage.directorySize(location.directory),
                    audioBytes: audioBytes
                )
            }
            if let libraryURL {
                report.libraryBytes = LibraryStorage.directorySize(libraryURL)
                report.availableBytes = LibraryStorage.availableCapacity(at: libraryURL)
            }
            if measuresEverything { report.modelsBytes = LibraryStorage.modelsSize() }
            return report
        }.value
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

    /// Moves several recordings to the macOS Trash. Those being transcribed or
    /// identified stay, as they do one at a time.
    func deleteRecordings(_ recordingIDs: Set<Recording.ID>) async {
        let ids = recordings.map(\.id).filter { recordingIDs.contains($0) && !isProcessing($0) }
        guard !ids.isEmpty else { return }
        recordingActionErrorMessage = nil
        recordingActionFeedback = nil

        do {
            let activeStore = try resolveStore()
            for id in ids {
                try await activeStore.moveToTrash(id: id)
                recordings.removeAll { $0.id == id }
                issues.removeAll { $0.recordingID == id }
                if selectedIDs.contains(id) {
                    selectedIDs.remove(id)
                    if selectedIDs.isEmpty {
                        transcript = nil
                        playback.unload()
                    }
                }
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
        // Read the waveform now, so it is ready when the player or the empty transcript
        // shows it.
        AudioWaveformOverviewModel.preload(
            playback.loadedTracks,
            resolution: RecordingWaveform.resolution(for: playback.duration > 0 ? playback.duration : recording.duration ?? 0)
        )
        await applySkipping()
    }

    /// Long silences of each recording, found once and kept for the session.
    private var silentRanges: [Recording.ID: [ClosedRange<TimeInterval>]] = [:]

    /// Plays only what `speakers` say in a recording; nil lets everyone through again.
    func setListenedSpeakers(_ speakers: Set<Speaker.ID>?, for recordingID: Recording.ID) async {
        listenedSpeakers[recordingID] = speakers
        await applySkipping()
    }

    /// Has the player jump over what the selected recording asks to skip: the turns of
    /// participants left out of listening, and long silences.
    func applySkipping() async {
        guard let recording = selectedRecording else {
            playback.skippedRanges = []
            return
        }
        var ranges: [ClosedRange<TimeInterval>] = []
        if let transcript, transcript.recordingID == recording.id,
           let listened = listenedSpeakers[recording.id] {
            // Participants merged away since they were chosen no longer count.
            let speakers = listened.intersection(transcript.speakers.map(\.id))
            if !speakers.isEmpty {
                let duration = max(playback.duration, recording.duration ?? 0)
                ranges += SpeakerPlaybackFilter.skippedRanges(of: transcript, keeping: speakers, duration: duration)
            }
        }
        if recording.skipsSilences {
            ranges += await longSilences(of: recording.id)
        }
        guard selection == recording.id else { return }
        playback.skippedRanges = SpeakerPlaybackFilter.merged(ranges)
    }

    /// The long silences of the selected recording, found once its audio is loaded and
    /// kept for the session; empty while there is no audio to read.
    func longSilences(of recordingID: Recording.ID) async -> [ClosedRange<TimeInterval>] {
        if let ranges = silentRanges[recordingID] { return ranges }
        let tracks = playback.loadedTracks
        guard selection == recordingID, !tracks.isEmpty else { return [] }
        let ranges = await Task.detached(priority: .utility) {
            (try? AudioWaveformOverview.silentRanges(of: tracks)) ?? []
        }.value
        silentRanges[recordingID] = ranges
        return ranges
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
        let remaining = selectedIDs.filter { id in recordings.contains { $0.id == id } }
        if !remaining.isEmpty {
            if remaining != selectedIDs { selectedIDs = remaining }
            return
        }
        selection = recordings.first { !$0.isArchived }?.id
    }
}
