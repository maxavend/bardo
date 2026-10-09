import Foundation

actor SystemAudioCaptureStagingStore {
    struct PreparedCapture: Equatable, Sendable {
        let recordingID: UUID
        let systemAssetID: UUID
        let microphoneAssetID: UUID?
        let mixAssetID: UUID?
        let directoryURL: URL
        let systemURL: URL
        let microphoneURL: URL?
        let mixURL: URL?
    }

    enum StagingError: Error, LocalizedError, Equatable, Sendable {
        case captureAlreadyPrepared
        case captureNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case .captureAlreadyPrepared:
                return String(localized: "Another system-audio capture is already prepared.")
            case .captureNotFound(let id):
                return String(localized: "System-audio staging for \(id.uuidString) was not found.")
            }
        }
    }

    static let directoryName = ".SystemAudioCaptureStaging"

    private let rootURL: URL
    private var activeRecordingID: UUID?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> SystemAudioCaptureStagingStore {
        SystemAudioCaptureStagingStore(rootURL: try liveRootURL())
    }

    static func liveRootURL() throws -> URL {
        let libraryURL = try RecordingStore.defaultLibraryURL()
        return libraryURL.deletingLastPathComponent().appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func prepareCapture(
        recordingID: UUID,
        systemAssetID: UUID,
        microphoneAssetID: UUID?,
        mixAssetID: UUID?,
        title: String? = nil,
        startedAt: Date = Date()
    ) throws -> PreparedCapture {
        guard activeRecordingID == nil else {
            throw StagingError.captureAlreadyPrepared
        }

        try DurableFile.createPrivateDirectory(at: rootURL)
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw StagingError.captureAlreadyPrepared
        }
        try DurableFile.createPrivateDirectory(at: directory)

        do {
            try CaptureStagingManifest(
                recordingID: recordingID,
                kind: microphoneAssetID == nil ? .systemAudio : .systemAudioAndMicrophone,
                title: title,
                startedAt: startedAt,
                systemAssetID: systemAssetID,
                microphoneAssetID: microphoneAssetID,
                mixAssetID: mixAssetID
            ).write(into: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        activeRecordingID = recordingID
        return PreparedCapture(
            recordingID: recordingID,
            systemAssetID: systemAssetID,
            microphoneAssetID: microphoneAssetID,
            mixAssetID: mixAssetID,
            directoryURL: directory,
            systemURL: directory.appendingPathComponent("\(systemAssetID.uuidString).m4a"),
            microphoneURL: microphoneAssetID.map { directory.appendingPathComponent("\($0.uuidString).m4a") },
            mixURL: mixAssetID.map { directory.appendingPathComponent("\($0.uuidString).m4a") }
        )
    }

    func finishActiveCapture(recordingID: UUID) {
        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
    }

    func discardCapture(recordingID: UUID) throws {
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if activeRecordingID == recordingID { activeRecordingID = nil }
            return
        }
        try FileManager.default.removeItem(at: directory)
        if activeRecordingID == recordingID { activeRecordingID = nil }
    }

    func moveToTrash(recordingID: UUID) throws {
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if activeRecordingID == recordingID { activeRecordingID = nil }
            return
        }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        if activeRecordingID == recordingID { activeRecordingID = nil }
    }

    /// Removes what is left of a capture after a recovery published part of it. Readable
    /// audio that was not published stays for another recovery; unreadable leftovers go
    /// to the Trash instead of being deleted.
    func finishRecovery(recordingID: UUID, reader: AudioMetadataReader) throws {
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let remaining = StagedCaptureContents.load(recordingID: recordingID, directoryURL: directory)
        if !remaining.readableAudioFiles(using: reader).isEmpty { return }
        if remaining.audioFiles.isEmpty {
            try FileManager.default.removeItem(at: directory)
        } else {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
    }

    /// Records where each source starts on the recording timeline.
    func recordTimeline(recordingID: UUID, systemOffset: TimeInterval?, microphoneOffset: TimeInterval?) {
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard var manifest = CaptureStagingManifest.read(from: directory) else { return }
        manifest.systemTimelineOffset = systemOffset
        manifest.microphoneTimelineOffset = microphoneOffset
        try? manifest.write(into: directory)
    }

    /// The staged files of a capture that is not currently recording.
    func contents(recordingID: UUID) -> StagedCaptureContents? {
        guard activeRecordingID != recordingID else { return nil }
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return StagedCaptureContents.load(recordingID: recordingID, directoryURL: directory)
    }

    func recoveryIssues() throws -> [RecordingStoreIssue] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return entries.compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent), id != activeRecordingID else { return nil }
            let contents = StagedCaptureContents.load(recordingID: id, directoryURL: entry)
            return RecordingStoreIssue(
                kind: .temporaryAudioArtifact,
                recordingID: id,
                entryName: contents.displayName,
                message: "Bardo preserved an incomplete system-audio capture for recovery."
            )
        }
    }
}
