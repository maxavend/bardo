import Foundation
import XCTest
@testable import Bardo

final class RecordingStoreRecoveryTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testCorruptRecordingDoesNotHideHealthyNeighbors() async throws {
        let a = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            title: "A",
            createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let bID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let c = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            title: "C",
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(a)
        try await store.save(c)
        try writeRawManifest(Data("{ definitely-not-json".utf8), for: bID)

        let restartedStore = RecordingStore(rootURL: rootURL)
        let snapshot = try await restartedStore.loadLibrary()

        XCTAssertEqual(snapshot.recordings, [c, a])
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertEqual(snapshot.issues.first?.kind, .corruptManifest)
        XCTAssertEqual(snapshot.issues.first?.recordingID, bID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL(for: bID).path))
    }

    func testIncompleteManifestIsReportedAndPreserved() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
        let incomplete = Data("{\"schemaVersion\":1,\"id\":\"\(id.uuidString)\"}".utf8)
        try writeRawManifest(incomplete, for: id)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.kind), [.corruptManifest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL(for: id).path))
    }

    func testUnsupportedSchemaIsDetectedWithoutMigrationOrDeletion() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        try writeRawManifest(Data("{\"schemaVersion\":99}".utf8), for: id)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.kind), [.unsupportedSchemaVersion])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL(for: id).path))
    }

    func testTemporaryWriteResidueDoesNotReplaceValidManifest() async throws {
        let recording = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000331")!,
            title: "Valid",
            createdAt: Date(timeIntervalSince1970: 1_700_000_600)
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)

        let tempURL = recordingDirectoryURL(for: recording.id)
            .appendingPathComponent(".manifest-interrupted.tmp")
        try Data("partial".utf8).write(to: tempURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertEqual(snapshot.recordings, [recording])
        XCTAssertEqual(snapshot.issues.map(\.kind), [.temporaryArtifact])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testTemporaryOnlyRecordingIsDetectedAsIncompleteAndPreserved() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000341")!
        let directoryURL = recordingDirectoryURL(for: id)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let tempURL = directoryURL.appendingPathComponent(".manifest-interrupted.tmp")
        try Data("partial".utf8).write(to: tempURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertEqual(Set(snapshot.issues.map(\.kind)), Set([.temporaryArtifact, .missingManifest]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testRecordingWithoutTranscriptIsAValidPersistedState() async throws {
        let recording = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000351")!,
            title: "Awaiting transcription",
            createdAt: Date(timeIntervalSince1970: 1_700_000_700)
        )
        let store = RecordingStore(rootURL: rootURL)

        try await store.save(recording)
        let loaded = try await RecordingStore(rootURL: rootURL).read(id: recording.id)

        XCTAssertEqual(loaded, recording)
        XCTAssertEqual(loaded.processingState, .pending)
    }

    private func makeRecording(id: UUID, title: String, createdAt: Date) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: nil,
            sources: [],
            processingState: .pending
        )
    }

    private func writeRawManifest(_ data: Data, for id: UUID) throws {
        let directoryURL = recordingDirectoryURL(for: id)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: manifestURL(for: id))
    }

    private func recordingDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        recordingDirectoryURL(for: id).appendingPathComponent(RecordingStore.manifestFileName)
    }
}
