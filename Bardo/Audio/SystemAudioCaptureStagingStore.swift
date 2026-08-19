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
                return "Another system-audio capture is already prepared."
            case .captureNotFound(let id):
                return "System-audio staging for \(id.uuidString) was not found."
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
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        return SystemAudioCaptureStagingStore(rootURL: root)
    }

    func prepareCapture(
        recordingID: UUID,
        systemAssetID: UUID,
        microphoneAssetID: UUID?,
        mixAssetID: UUID?
    ) throws -> PreparedCapture {
        guard activeRecordingID == nil else {
            throw StagingError.captureAlreadyPrepared
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw StagingError.captureAlreadyPrepared
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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

    func recoveryIssues() throws -> [RecordingStoreIssue] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return entries.compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent), id != activeRecordingID else { return nil }
            return RecordingStoreIssue(
                kind: .temporaryAudioArtifact,
                recordingID: id,
                entryName: entry.lastPathComponent,
                message: "Bardo preserved an incomplete system-audio capture for recovery."
            )
        }
    }
}
