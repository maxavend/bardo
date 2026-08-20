#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct TranscriptDocumentV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let transcript: Transcript

    init(transcript: Transcript) {
        schemaVersion = Self.schemaVersion
        self.transcript = transcript
    }
}

enum TranscriptStoreError: Error, LocalizedError, Equatable, Sendable {
    case recordingNotFound(Recording.ID)
    case transcriptNotFound(Recording.ID)
    case unsupportedSchemaVersion(Int)
    case invalidTranscript(String)
    case identityMismatch(expected: Recording.ID, actual: Recording.ID)
    case fileSystem(operation: String, entry: String, description: String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id):
            return "Recording \(id.uuidString) was not found."
        case .transcriptNotFound(let id):
            return "Recording \(id.uuidString) has no transcript yet."
        case .unsupportedSchemaVersion(let version):
            return "Transcript schema version \(version) is not supported."
        case .invalidTranscript(let description):
            return "The transcript is invalid: \(description)"
        case .identityMismatch(let expected, let actual):
            return "Transcript identity \(actual.uuidString) does not match recording \(expected.uuidString)."
        case .fileSystem(let operation, let entry, let description):
            return "Could not \(operation) \(entry): \(description)"
        }
    }
}

private struct TranscriptDocumentHeader: Decodable {
    let schemaVersion: Int
}

actor TranscriptStore {
    static let transcriptFileName = "transcript.json"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> TranscriptStore {
        TranscriptStore(rootURL: try RecordingStore.defaultLibraryURL())
    }

    func save(_ transcript: Transcript) throws {
        let recordingDirectory = rootURL
            .appendingPathComponent(transcript.recordingID.uuidString, isDirectory: true)
        let manifestURL = recordingDirectory.appendingPathComponent(RecordingStore.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw TranscriptStoreError.recordingNotFound(transcript.recordingID)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(TranscriptDocumentV1(transcript: transcript))
        let destination = recordingDirectory.appendingPathComponent(Self.transcriptFileName)
        let temporary = recordingDirectory
            .appendingPathComponent(".transcript-\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: [])
            try atomicallyMove(from: temporary, to: destination)
        } catch let error as TranscriptStoreError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw TranscriptStoreError.fileSystem(
                operation: "write transcript",
                entry: transcript.recordingID.uuidString,
                description: error.localizedDescription
            )
        }
    }

    func read(recordingID: Recording.ID) throws -> Transcript? {
        let url = transcriptURL(recordingID: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TranscriptStoreError.fileSystem(
                operation: "read transcript",
                entry: recordingID.uuidString,
                description: error.localizedDescription
            )
        }

        let decoder = JSONDecoder()
        let header: TranscriptDocumentHeader
        do {
            header = try decoder.decode(TranscriptDocumentHeader.self, from: data)
        } catch {
            throw TranscriptStoreError.invalidTranscript(error.localizedDescription)
        }
        guard header.schemaVersion == TranscriptDocumentV1.schemaVersion else {
            throw TranscriptStoreError.unsupportedSchemaVersion(header.schemaVersion)
        }

        do {
            let document = try decoder.decode(TranscriptDocumentV1.self, from: data)
            guard document.transcript.recordingID == recordingID else {
                throw TranscriptStoreError.identityMismatch(
                    expected: recordingID,
                    actual: document.transcript.recordingID
                )
            }
            return document.transcript
        } catch let error as TranscriptStoreError {
            throw error
        } catch {
            throw TranscriptStoreError.invalidTranscript(error.localizedDescription)
        }
    }

    func temporaryArtifacts(recordingID: Recording.ID) -> [URL] {
        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix(".transcript-") && $0.pathExtension == "tmp"
        }
    }

    private func transcriptURL(recordingID: Recording.ID) -> URL {
        rootURL
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.transcriptFileName)
    }

    private func atomicallyMove(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw TranscriptStoreError.fileSystem(
                operation: "atomically replace transcript",
                entry: destinationURL.lastPathComponent,
                description: String(cString: strerror(code))
            )
        }
    }
}
