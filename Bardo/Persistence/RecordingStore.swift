#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

actor RecordingStore {
    static let manifestFileName = "manifest.json"

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

            issues.append(contentsOf: temporaryArtifactIssues(in: entry, recordingID: id))

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

    private func encode(_ recording: Recording) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(RecordingManifestV1(recording: recording))
    }

    private func decode(_ data: Data) throws -> Recording {
        let decoder = JSONDecoder()
        let header: RecordingManifestHeader
        do {
            header = try decoder.decode(RecordingManifestHeader.self, from: data)
        } catch {
            throw RecordingStoreError.invalidManifest(error.localizedDescription)
        }

        guard header.schemaVersion == RecordingManifestV1.currentSchemaVersion else {
            throw RecordingStoreError.unsupportedSchemaVersion(header.schemaVersion)
        }

        do {
            return try decoder.decode(RecordingManifestV1.self, from: data).recording
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

        let result = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                rename(temporaryPath, destinationPath)
            }
        }

        guard result == 0 else {
            let code = errno
            let description = String(cString: strerror(code))
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RecordingStoreError.fileSystem(
                operation: "atomically replace",
                entry: destinationURL.lastPathComponent,
                description: description
            )
        }
    }

    private func temporaryArtifactIssues(in directoryURL: URL, recordingID: UUID) -> [RecordingStoreIssue] {
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
