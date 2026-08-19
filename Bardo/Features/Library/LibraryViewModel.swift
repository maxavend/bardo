import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var issues: [RecordingStoreIssue] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var importErrorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published var selection: Recording.ID?

    let playback: AudioPlaybackController

    private var store: RecordingStore?
    private var importer: AudioImportService?

    init(
        store: RecordingStore? = nil,
        importer: AudioImportService? = nil,
        playback: AudioPlaybackController? = nil
    ) {
        self.store = store
        self.importer = importer
        self.playback = playback ?? AudioPlaybackController()
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
            reconcileSelection()
            await preparePlaybackForSelection()
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

    func preparePlaybackForSelection() async {
        playback.unload()
        guard let recording = selectedRecording else { return }
        guard let asset = recording.audioAssets.first else {
            playback.setUnavailable("This recording has no managed audio file.")
            return
        }

        let recordingID = recording.id
        do {
            let activeStore = try resolveStore()
            let url = try await activeStore.managedAudioURL(
                recordingID: recordingID,
                audioAssetID: asset.id
            )
            guard selection == recordingID else { return }
            playback.load(url: url)
        } catch {
            guard selection == recordingID else { return }
            playback.setUnavailable(error.localizedDescription)
        }
    }

    func stopPlayback() {
        playback.unload()
    }

    var selectedRecording: Recording? {
        guard let selection else { return nil }
        return recordings.first { $0.id == selection }
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

    private func reconcileSelection() {
        if let selection, recordings.contains(where: { $0.id == selection }) {
            return
        }
        selection = recordings.first?.id
    }
}
