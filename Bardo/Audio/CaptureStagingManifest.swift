import Foundation

/// Describes an in-progress capture next to its staged audio, so an interrupted
/// capture can be recovered with its title, start date and source roles.
struct CaptureStagingManifest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case microphone
        case systemAudio
        case systemAudioAndMicrophone
    }

    static let fileName = "capture.json"

    let recordingID: UUID
    let kind: Kind
    let title: String?
    let startedAt: Date
    let systemAssetID: UUID?
    let microphoneAssetID: UUID?
    let mixAssetID: UUID?
    /// Each source's start on the shared recording timeline, written when the capture
    /// stops so a recovery after an interrupted save keeps the sources aligned.
    var systemTimelineOffset: TimeInterval?
    var microphoneTimelineOffset: TimeInterval?

    init(
        recordingID: UUID,
        kind: Kind,
        title: String?,
        startedAt: Date,
        systemAssetID: UUID? = nil,
        microphoneAssetID: UUID? = nil,
        mixAssetID: UUID? = nil,
        systemTimelineOffset: TimeInterval? = nil,
        microphoneTimelineOffset: TimeInterval? = nil
    ) {
        self.recordingID = recordingID
        self.kind = kind
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed?.isEmpty == false ? trimmed : nil
        self.startedAt = startedAt
        self.systemAssetID = systemAssetID
        self.microphoneAssetID = microphoneAssetID
        self.mixAssetID = mixAssetID
        self.systemTimelineOffset = systemTimelineOffset
        self.microphoneTimelineOffset = microphoneTimelineOffset
    }

    func write(into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableFile.write(
            try encoder.encode(self),
            to: directory.appendingPathComponent(Self.fileName),
            temporaryPrefix: ".capture"
        )
    }

    static func read(from directory: URL) -> CaptureStagingManifest? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptureStagingManifest.self, from: data)
    }
}

/// Audio left behind by an interrupted capture, ready to be validated and published.
struct StagedCaptureContents: Equatable, Sendable {
    let recordingID: UUID
    let directoryURL: URL
    let manifest: CaptureStagingManifest?
    /// Staged audio files, excluding Bardo's own bookkeeping and temporary files.
    let audioFiles: [URL]
    let createdAt: Date?

    static let audioFileExtensions: Set<String> = ["m4a", "caf", "wav", "aiff", "aif"]

    static func load(recordingID: UUID, directoryURL: URL) -> StagedCaptureContents {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let audioFiles = entries
            .filter { audioFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let createdAt = (try? directoryURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return StagedCaptureContents(
            recordingID: recordingID,
            directoryURL: directoryURL,
            manifest: CaptureStagingManifest.read(from: directoryURL),
            audioFiles: audioFiles,
            createdAt: createdAt
        )
    }

    var startedAt: Date {
        manifest?.startedAt ?? createdAt ?? Date()
    }

    /// Staged audio files that can be read, keeping their staging order.
    func readableAudioFiles(using reader: AudioMetadataReader) -> [URL] {
        audioFiles.filter { (try? reader.read(from: $0)) != nil }
    }

    /// The name shown when reviewing interrupted captures.
    var displayName: String {
        if let title = manifest?.title {
            return title
        }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
