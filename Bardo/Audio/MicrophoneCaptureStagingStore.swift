import Foundation

actor MicrophoneCaptureStagingStore {
    static let directoryName = ".MicrophoneCaptureStaging"

    private let rootURL: URL
    private var activeCaptureID: UUID?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> MicrophoneCaptureStagingStore {
        MicrophoneCaptureStagingStore(rootURL: try liveRootURL())
    }

    static func liveRootURL() throws -> URL {
        let libraryURL = try RecordingStore.defaultLibraryURL()
        return libraryURL.deletingLastPathComponent().appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func prepareCapture(
        recordingID: UUID,
        audioAssetID: UUID,
        fileExtension: String,
        title: String? = nil,
        startedAt: Date = Date()
    ) throws -> URL {
        if let activeCaptureID {
            throw MicrophoneCaptureStagingError.captureAlreadyActive(activeCaptureID)
        }

        try ensureDirectoryExists(rootURL)
        let directory = captureDirectoryURL(for: recordingID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw MicrophoneCaptureStagingError.captureResidueExists(recordingID)
        }

        try ensureDirectoryExists(directory)
        do {
            try CaptureStagingManifest(
                recordingID: recordingID,
                kind: .microphone,
                title: title,
                startedAt: startedAt,
                microphoneAssetID: audioAssetID
            ).write(into: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw MicrophoneCaptureStagingError.fileSystem(error.localizedDescription)
        }

        activeCaptureID = recordingID
        return directory.appendingPathComponent(
            "\(audioAssetID.uuidString).\(fileExtension.lowercased())"
        )
    }

    func discardPreparedCapture(recordingID: UUID) throws {
        guard activeCaptureID == recordingID else {
            throw MicrophoneCaptureStagingError.captureNotActive(recordingID)
        }
        try discardCapture(recordingID: recordingID)
    }

    /// Removes a capture's staging directory whether it is active or left behind.
    func discardCapture(recordingID: UUID) throws {
        if activeCaptureID == recordingID {
            activeCaptureID = nil
        }

        let directory = captureDirectoryURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw MicrophoneCaptureStagingError.fileSystem(error.localizedDescription)
        }
    }

    func moveToTrash(recordingID: UUID) throws {
        let directory = captureDirectoryURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if activeCaptureID == recordingID { activeCaptureID = nil }
            return
        }
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            if activeCaptureID == recordingID { activeCaptureID = nil }
        } catch {
            throw MicrophoneCaptureStagingError.fileSystem(error.localizedDescription)
        }
    }

    func preserveInterruptedCapture(recordingID: UUID) {
        if activeCaptureID == recordingID {
            activeCaptureID = nil
        }
    }

    /// The staged files of a capture that is not currently recording.
    func contents(recordingID: UUID) -> StagedCaptureContents? {
        guard activeCaptureID != recordingID else { return nil }
        let directory = captureDirectoryURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return StagedCaptureContents.load(recordingID: recordingID, directoryURL: directory)
    }

    func recoveryIssues() -> [RecordingStoreIssue] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories.compactMap { directory -> RecordingStoreIssue? in
            guard let recordingID = UUID(uuidString: directory.lastPathComponent) else {
                return RecordingStoreIssue(
                    kind: .temporaryAudioArtifact,
                    recordingID: nil,
                    entryName: directory.lastPathComponent,
                    message: "An unrecognized microphone capture residue was preserved."
                )
            }

            if activeCaptureID == recordingID {
                return nil
            }

            let contents = StagedCaptureContents.load(recordingID: recordingID, directoryURL: directory)
            return RecordingStoreIssue(
                kind: .temporaryAudioArtifact,
                recordingID: recordingID,
                entryName: contents.displayName,
                message: contents.audioFiles.isEmpty
                    ? "An incomplete microphone capture directory was detected and preserved."
                    : "An incomplete microphone capture was detected and preserved."
            )
        }
    }

    private func captureDirectoryURL(for recordingID: UUID) -> URL {
        rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        do {
            try DurableFile.createPrivateDirectory(at: url)
        } catch {
            throw MicrophoneCaptureStagingError.fileSystem(error.localizedDescription)
        }
    }
}

enum MicrophoneCaptureStagingError: Error, LocalizedError, Equatable, Sendable {
    case captureAlreadyActive(UUID)
    case captureNotActive(UUID)
    case captureResidueExists(UUID)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .captureAlreadyActive:
            return String(localized: "A microphone capture is already active.")
        case .captureNotActive:
            return String(localized: "The microphone capture is no longer active.")
        case .captureResidueExists:
            return String(localized: "Bardo found existing temporary data for this capture and left it untouched.")
        case .fileSystem(let description):
            return String(localized: "Microphone capture storage failed: \(description)")
        }
    }
}
