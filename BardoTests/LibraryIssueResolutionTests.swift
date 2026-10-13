import XCTest
@testable import Bardo

final class LibraryIssueResolutionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoIssues-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The leftover an earlier Bardo left behind: a folder with only meeting minutes.
    func testFolderWithoutManifestIsReportedAndCanBeTrashed() async throws {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meeting-minutes.json"))

        let store = RecordingStore(rootURL: root)
        let snapshot = try await store.loadLibrary()
        let issue = try XCTUnwrap(snapshot.issues.first)
        XCTAssertEqual(issue.kind, .missingManifest)
        XCTAssertTrue(issue.canMoveToTrash)
        let url = await store.itemURL(for: issue)
        XCTAssertEqual(url?.standardizedFileURL, folder.standardizedFileURL)
    }

    /// Data from a newer Bardo, missing audio and inconsistent conversations stay put.
    func testOnlyIssuesThatCannotTakeAConversationWithThemAreTrashable() {
        let trashable: Set<RecordingStoreIssue.Kind> = [
            .missingManifest, .corruptManifest, .unexpectedEntry, .temporaryArtifact, .temporaryAudioArtifact
        ]
        for kind in [RecordingStoreIssue.Kind.missingManifest, .corruptManifest, .unsupportedSchemaVersion,
                     .identityMismatch, .temporaryArtifact, .temporaryAudioArtifact, .missingAudioFile,
                     .missingDerivedAudioFile, .unexpectedEntry, .unreadableEntry] {
            let issue = RecordingStoreIssue(kind: kind, recordingID: UUID(), entryName: "x", message: "")
            XCTAssertEqual(issue.canMoveToTrash, trashable.contains(kind), "\(kind)")
        }
    }

    func testRefusesToTrashProtectedKindsAndLeavesThemInPlace() async throws {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = RecordingStore(rootURL: root)
        let newer = RecordingStoreIssue(kind: .unsupportedSchemaVersion, recordingID: id, entryName: id.uuidString, message: "")

        do {
            try await store.moveIssueItemToTrash(newer)
            XCTFail("A conversation from a newer Bardo must not be trashed from the review.")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNeverResolvesOutsideTheLibrary() async {
        let store = RecordingStore(rootURL: root)
        for name in ["..", ".", "../escape", "a/b", ""] {
            let issue = RecordingStoreIssue(kind: .unexpectedEntry, recordingID: nil, entryName: name, message: "")
            let url = await store.itemURL(for: issue)
            XCTAssertNil(url, "Resolved \(name)")
        }
    }
}
