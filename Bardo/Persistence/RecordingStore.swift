#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

actor RecordingStore {
    static let manifestFileName = "manifest.json"
    static let audioDirectoryName = "audio"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> RecordingStore {
        RecordingStore(rootURL: try defaultLibraryURL())
    }

    static func defaultLibraryURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    func save(_ recording: Recording) throws {
        let data = try encode(recording)
        let directoryURL = recordingDirectoryURL(for: recording.id)
        try ensureDirectoryExists(directoryURL)
        try atomicallyWrite(data, to: manifestURL(for: recording.id), in: directoryURL)
    }

    func update(_ recording: Recording) throws {
        guard FileManager.default.fileExists(atPath: manifestURL(for: recording.id).path) else {
            throw RecordingStoreError.recordingNotFound(recording.id)
        }
        try save(recording)
    }

    func importRecording(
        _ recording: Recording,
        audioAsset: AudioAsset,
        from sourceURL: URL
    ) throws {
        try importRecording(recording, audioFiles: [audioAsset.id: sourceURL])
    }

    func importRecording(
        _ recording: Recording,
        audioFiles: [AudioAsset.ID: URL]
    ) throws {
        let expectedIDs = Set(recording.audioAssets.map(\.id))
        let suppliedIDs = Set(audioFiles.keys)
        guard !expectedIDs.isEmpty, expectedIDs == suppliedIDs else {
            throw RecordingStoreError.audioAssetFileSetMismatch(
                recordingID: recording.id,
                expected: expectedIDs.count,
                supplied: suppliedIDs.count
            )
        }

        let data = try encode(recording)
        try ensureDirectoryExists(rootURL)

        let recordingDirectory = recordingDirectoryURL(for: recording.id)
        guard !FileManager.default.fileExists(atPath: recordingDirectory.path) else {
            throw RecordingStoreError.recordingAlreadyExists(recording.id)
        }

        do {
            try ensureDirectoryExists(recordingDirectory)
            let audioDirectory = audioDirectoryURL(for: recording.id)
            try ensureDirectoryExists(audioDirectory)

            for asset in recording.audioAssets {
                guard let sourceURL = audioFiles[asset.id] else {
                    throw RecordingStoreError.audioAssetNotFound(
                        recordingID: recording.id,
                        audioAssetID: asset.id
                    )
                }

                let temporaryAudioURL = audioDirectory
                    .appendingPathComponent(".audio-\(asset.id.uuidString).tmp")
                let destinationAudioURL = managedAudioURL(
                    recordingID: recording.id,
                    asset: asset
                )

                do {
                    try FileManager.default.copyItem(at: sourceURL, to: temporaryAudioURL)
                } catch {
                    throw RecordingStoreError.fileSystem(
                        operation: "copy managed audio",
                        entry: sourceURL.lastPathComponent,
                        description: error.localizedDescription
                    )
                }

                try atomicallyMove(
                    from: temporaryAudioURL,
                    to: destinationAudioURL,
                    operation: "finalize managed audio"
                )
            }

            // All managed audio files are final before the manifest becomes visible.
            try atomicallyWrite(
                data,
                to: manifestURL(for: recording.id),
                in: recordingDirectory
            )
        } catch {
            // This directory was created exclusively for this failed publication. Removing
            // it cannot affect an existing recording or the caller-owned staging sources.
            try? FileManager.default.removeItem(at: recordingDirectory)
            throw error
        }
    }

    func read(id: Recording.ID) throws -> Recording {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingStoreError.recordingNotFound(id)
        }

        do {
            let data = try Data(contentsOf: url)
            let recording = try decode(data)
            guard recording.id == id else {
                throw RecordingStoreError.identityMismatch(expected: id, actual: recording.id)
            }
            return recording
        } catch let error as RecordingStoreError {
            throw error
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "read",
                entry: id.uuidString,
                description: error.localizedDescription
            )
        }
    }

    func managedAudioURL(recordingID: Recording.ID, audioAssetID: AudioAsset.ID) throws -> URL {
        let recording = try read(id: recordingID)
        guard let asset = recording.audioAssets.first(where: { $0.id == audioAssetID }) else {
            throw RecordingStoreError.audioAssetNotFound(
                recordingID: recordingID,
                audioAssetID: audioAssetID
            )
        }

        let url = managedAudioURL(recordingID: recordingID, asset: asset)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingStoreError.managedAudioMissing(
                recordingID: recordingID,
                audioAssetID: audioAssetID
            )
        }
        return url
    }

    func recordingDirectoryURL(recordingID: Recording.ID) throws -> URL {
        // UUIDs cannot introduce path traversal. Returning a path derived only from the
        // store root keeps Finder actions scoped to Bardo's managed library.
        rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    func loadLibrary() throws -> LibrarySnapshot {
        try ensureDirectoryExists(rootURL)

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "list",
                entry: "library",
                description: error.localizedDescription
            )
        }

        var recordings: [Recording] = []
        var issues: [RecordingStoreIssue] = []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                issues.append(issue(
                    kind: .unreadableEntry,
                    recordingID: nil,
                    entryName: entry.lastPathComponent,
                    message: "A library entry could not be inspected and was left untouched."
                ))
                continue
            }

            guard values.isDirectory == true,
                  let id = UUID(uuidString: entry.lastPathComponent) else {
                issues.append(issue(
                    kind: .unexpectedEntry,
                    recordingID: nil,
                    entryName: entry.lastPathComponent,
                    message: "An unexpected library entry was preserved and ignored."
                ))
                continue
            }

            issues.append(contentsOf: temporaryManifestArtifactIssues(in: entry, recordingID: id))
            issues.append(contentsOf: temporaryAudioArtifactIssues(in: entry, recordingID: id))

            let manifestURL = entry.appendingPathComponent(Self.manifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                issues.append(issue(
                    kind: .missingManifest,
                    recordingID: id,
                    entryName: id.uuidString,
                    message: "Recording \(id.uuidString) has no complete manifest and was left untouched."
                ))
                continue
            }

            do {
                let data = try Data(contentsOf: manifestURL)
                let recording = try decode(data)
                guard recording.id == id else {
                    issues.append(issue(
                        kind: .identityMismatch,
                        recordingID: id,
                        entryName: id.uuidString,
                        message: "A recording manifest has a mismatched identity and was not loaded."
                    ))
                    continue
                }
                recordings.append(recording)
                issues.append(contentsOf: managedAudioIssues(for: recording))
            } catch RecordingStoreError.unsupportedSchemaVersion(let version) {
                issues.append(issue(
                    kind: .unsupportedSchemaVersion,
                    recordingID: id,
                    entryName: id.uuidString,
                    message: "Recording \(id.uuidString) uses unsupported manifest schema version \(version) and was preserved."
                ))
            } catch {
                issues.append(issue(
                    kind: .corruptManifest,
                    recordingID: id,
                    entryName: id.uuidString,
                    message: "Recording \(id.uuidString) has an unreadable or incomplete manifest and was preserved."
                ))
            }
        }

        recordings.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt > $1.createdAt
        }

        return LibrarySnapshot(recordings: recordings, issues: issues)
    }

    func delete(id: Recording.ID) throws {
        let directoryURL = recordingDirectoryURL(for: id)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw RecordingStoreError.recordingNotFound(id)
        }

        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "delete",
                entry: id.uuidString,
                description: error.localizedDescription
            )
        }
    }

    func moveToTrash(id: Recording.ID) throws {
        let directoryURL = recordingDirectoryURL(for: id)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw RecordingStoreError.recordingNotFound(id)
        }

        do {
            try FileManager.default.trashItem(at: directoryURL, resultingItemURL: nil)
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "move recording to Trash",
                entry: id.uuidString,
                description: error.localizedDescription
            )
        }
    }

    private func encode(_ recording: Recording) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(RecordingManifestV3(recording: recording))
    }

    private func decode(_ data: Data) throws -> Recording {
        let decoder = JSONDecoder()
        let header: RecordingManifestHeader
        do {
            header = try decoder.decode(RecordingManifestHeader.self, from: data)
        } catch {
            throw RecordingStoreError.invalidManifest(error.localizedDescription)
        }

        do {
            switch header.schemaVersion {
            case RecordingManifestV1.schemaVersion:
                return try decoder.decode(RecordingManifestV1.self, from: data).recording
            case RecordingManifestV2.currentSchemaVersion:
                return try decoder.decode(RecordingManifestV2.self, from: data).recording
            case RecordingManifestV3.currentSchemaVersion:
                return try decoder.decode(RecordingManifestV3.self, from: data).recording
            default:
                throw RecordingStoreError.unsupportedSchemaVersion(header.schemaVersion)
            }
        } catch let error as RecordingStoreError {
            throw error
        } catch {
            throw RecordingStoreError.invalidManifest(error.localizedDescription)
        }
    }

    private func recordingDirectoryURL(for id: Recording.ID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(for id: Recording.ID) -> URL {
        recordingDirectoryURL(for: id).appendingPathComponent(Self.manifestFileName)
    }

    private func audioDirectoryURL(for id: Recording.ID) -> URL {
        recordingDirectoryURL(for: id)
            .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
    }

    private func managedAudioURL(recordingID: Recording.ID, asset: AudioAsset) -> URL {
        audioDirectoryURL(for: recordingID)
            .appendingPathComponent("\(asset.id.uuidString).\(asset.fileExtension)")
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "create directory for",
                entry: url.lastPathComponent,
                description: error.localizedDescription
            )
        }
    }

    private func atomicallyWrite(_ data: Data, to destinationURL: URL, in directoryURL: URL) throws {
        let temporaryURL = directoryURL.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporaryURL, options: [])
        } catch {
            throw RecordingStoreError.fileSystem(
                operation: "write temporary manifest",
                entry: destinationURL.lastPathComponent,
                description: error.localizedDescription
            )
        }

        do {
            try atomicallyMove(
                from: temporaryURL,
                to: destinationURL,
                operation: "atomically replace manifest"
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func atomicallyMove(from sourceURL: URL, to destinationURL: URL, operation: String) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }

        guard result == 0 else {
            let code = errno
            throw RecordingStoreError.fileSystem(
                operation: operation,
                entry: destinationURL.lastPathComponent,
                description: String(cString: strerror(code))
            )
        }
    }

    private func temporaryManifestArtifactIssues(in directoryURL: URL, recordingID: UUID) -> [RecordingStoreIssue] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        return entries
            .filter { $0.lastPathComponent.hasPrefix(".manifest-") && $0.pathExtension == "tmp" }
            .map { temporaryURL in
                issue(
                    kind: .temporaryArtifact,
                    recordingID: recordingID,
                    entryName: temporaryURL.lastPathComponent,
                    message: "An incomplete manifest write was detected for recording \(recordingID.uuidString) and was preserved."
                )
            }
    }

    private func temporaryAudioArtifactIssues(in recordingDirectoryURL: URL, recordingID: UUID) -> [RecordingStoreIssue] {
        let audioDirectory = recordingDirectoryURL
            .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        return entries
            .filter { $0.lastPathComponent.hasPrefix(".audio-") && $0.pathExtension == "tmp" }
            .map { temporaryURL in
                issue(
                    kind: .temporaryAudioArtifact,
                    recordingID: recordingID,
                    entryName: temporaryURL.lastPathComponent,
                    message: "An incomplete audio publication was detected for recording \(recordingID.uuidString) and was preserved."
                )
            }
    }

    private func managedAudioIssues(for recording: Recording) -> [RecordingStoreIssue] {
        recording.audioAssets.compactMap { asset in
            let url = managedAudioURL(recordingID: recording.id, asset: asset)
            guard !FileManager.default.fileExists(atPath: url.path) else { return nil }

            if asset.role.isDerived {
                return issue(
                    kind: .missingDerivedAudioFile,
                    recordingID: recording.id,
                    entryName: asset.id.uuidString,
                    message: "A derived playback asset for \(recording.title) is missing. Original source audio was preserved."
                )
            }

            return issue(
                kind: .missingAudioFile,
                recordingID: recording.id,
                entryName: asset.id.uuidString,
                message: "Managed source audio for \(recording.title) is missing. Its manifest was preserved."
            )
        }
    }

    private func issue(
        kind: RecordingStoreIssue.Kind,
        recordingID: UUID?,
        entryName: String,
        message: String
    ) -> RecordingStoreIssue {
        RecordingStoreIssue(
            kind: kind,
            recordingID: recordingID,
            entryName: entryName,
            message: message
        )
    }
}
