import Foundation

actor MicrophoneCaptureStagingStore {
    static let directoryName = ".MicrophoneCaptureStaging"

    private let rootURL: URL
    private var activeCaptureID: UUID?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> MicrophoneCaptureStagingStore {
        let libraryURL = try RecordingStore.defaultLibraryURL()
        return MicrophoneCaptureStagingStore(
            rootURL: libraryURL
                .deletingLastPathComponent()
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    static func liveRootURL() throws -> URL {
        let libraryURL = try RecordingStore.defaultLibraryURL()
        return libraryURL.deletingLastPathComponent().appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func prepareCapture(
        recordingID: UUID,
        audioAssetID: UUID,
        fileExtension: String
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
        activeCaptureID = recordingID
        return directory.appendingPathComponent(
            "\(audioAssetID.uuidString).\(fileExtension.lowercased())"
        )
    }

    func discardPreparedCapture(recordingID: UUID) throws {
        guard activeCaptureID == recordingID else {
            throw MicrophoneCaptureStagingError.captureNotActive(recordingID)
        }
        activeCaptureID = nil

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

    func recoveryIssues() -> [RecordingStoreIssue] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories.flatMap { directory -> [RecordingStoreIssue] in
            guard let recordingID = UUID(uuidString: directory.lastPathComponent) else {
                return [RecordingStoreIssue(
                    kind: .temporaryAudioArtifact,
                    recordingID: nil,
                    entryName: directory.lastPathComponent,
                    message: "An unrecognized microphone capture residue was preserved."
                )]
            }

            if activeCaptureID == recordingID {
                return []
            }

            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []

            if files.isEmpty {
                return [RecordingStoreIssue(
                    kind: .temporaryAudioArtifact,
                    recordingID: recordingID,
                    entryName: recordingID.uuidString,
                    message: "An incomplete microphone capture directory was detected and preserved."
                )]
            }

            return files.map { file in
                RecordingStoreIssue(
                    kind: .temporaryAudioArtifact,
                    recordingID: recordingID,
                    entryName: file.lastPathComponent,
                    message: "An incomplete microphone capture was detected and preserved."
                )
            }
        }
    }

    private func captureDirectoryURL(for recordingID: UUID) -> URL {
        rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
            return "A microphone capture is already active."
        case .captureNotActive:
            return "The microphone capture is no longer active."
        case .captureResidueExists:
            return "Bardo found existing temporary data for this capture and left it untouched."
        case .fileSystem(let description):
            return "Microphone capture storage failed: \(description)"
        }
    }
}
