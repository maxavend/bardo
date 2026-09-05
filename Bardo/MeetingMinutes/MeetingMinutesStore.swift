import Foundation

struct MeetingMinutesDocumentV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let minutes: MeetingMinutes

    init(minutes: MeetingMinutes) {
        schemaVersion = Self.schemaVersion
        self.minutes = minutes
    }
}

enum MeetingMinutesStoreError: Error, LocalizedError, Equatable, Sendable {
    case recordingNotFound(Recording.ID)
    case unsupportedSchemaVersion(Int)
    case invalidMinutes(String)
    case identityMismatch(expected: Recording.ID, actual: Recording.ID)
    case fileSystem(operation: String, entry: String, description: String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id):
            return "Recording \(id.uuidString) was not found."
        case .unsupportedSchemaVersion(let version):
            return "Meeting-minutes schema version \(version) is not supported."
        case .invalidMinutes(let description):
            return "The meeting minutes are invalid: \(description)"
        case .identityMismatch(let expected, let actual):
            return "Meeting-minutes identity \(actual.uuidString) does not match recording \(expected.uuidString)."
        case .fileSystem(let operation, let entry, let description):
            return "Could not \(operation) \(entry): \(description)"
        }
    }
}

private struct MeetingMinutesDocumentHeader: Decodable {
    let schemaVersion: Int
}

actor MeetingMinutesStore {
    static let meetingMinutesFileName = "meeting-minutes.json"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static func live() throws -> MeetingMinutesStore {
        MeetingMinutesStore(rootURL: try RecordingStore.defaultLibraryURL())
    }

    func save(_ minutes: MeetingMinutes) throws {
        let directory = recordingDirectory(for: minutes.recordingID)
        let manifestURL = directory.appendingPathComponent(RecordingStore.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MeetingMinutesStoreError.recordingNotFound(minutes.recordingID)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(MeetingMinutesDocumentV1(minutes: minutes))
            try data.write(
                to: directory.appendingPathComponent(Self.meetingMinutesFileName),
                options: [.atomic]
            )
        } catch let error as MeetingMinutesStoreError {
            throw error
        } catch {
            throw MeetingMinutesStoreError.fileSystem(
                operation: "write meeting minutes",
                entry: minutes.recordingID.uuidString,
                description: error.localizedDescription
            )
        }
    }

    func read(recordingID: Recording.ID) throws -> MeetingMinutes? {
        let url = meetingMinutesURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let header = try decoder.decode(MeetingMinutesDocumentHeader.self, from: data)
            guard header.schemaVersion == MeetingMinutesDocumentV1.schemaVersion else {
                throw MeetingMinutesStoreError.unsupportedSchemaVersion(header.schemaVersion)
            }

            let document = try decoder.decode(MeetingMinutesDocumentV1.self, from: data)
            guard document.minutes.recordingID == recordingID else {
                throw MeetingMinutesStoreError.identityMismatch(
                    expected: recordingID,
                    actual: document.minutes.recordingID
                )
            }
            return document.minutes
        } catch let error as MeetingMinutesStoreError {
            throw error
        } catch {
            throw MeetingMinutesStoreError.invalidMinutes(error.localizedDescription)
        }
    }

    func delete(recordingID: Recording.ID) throws {
        let url = meetingMinutesURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeetingMinutesStoreError.fileSystem(
                operation: "delete meeting minutes",
                entry: recordingID.uuidString,
                description: error.localizedDescription
            )
        }
    }

    private func recordingDirectory(for id: Recording.ID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func meetingMinutesURL(for id: Recording.ID) -> URL {
        recordingDirectory(for: id).appendingPathComponent(Self.meetingMinutesFileName)
    }
}
