import XCTest
@testable import Bardo

func XCTAssertRecordingPersistenceEqual(
    _ actual: Recording,
    _ expected: Recording,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.id, expected.id, file: file, line: line)
    XCTAssertEqual(actual.title, expected.title, file: file, line: line)
    XCTAssertEqual(
        actual.createdAt.timeIntervalSince1970.bitPattern,
        expected.createdAt.timeIntervalSince1970.bitPattern,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.duration.map(\.bitPattern),
        expected.duration.map(\.bitPattern),
        file: file,
        line: line
    )
    XCTAssertEqual(actual.sources, expected.sources, file: file, line: line)
    XCTAssertEqual(actual.processingState, expected.processingState, file: file, line: line)
    XCTAssertEqual(actual.audioAssets.count, expected.audioAssets.count, file: file, line: line)

    for (actualAsset, expectedAsset) in zip(actual.audioAssets, expected.audioAssets) {
        XCTAssertEqual(actualAsset.id, expectedAsset.id, file: file, line: line)
        XCTAssertEqual(actualAsset.originalFileName, expectedAsset.originalFileName, file: file, line: line)
        XCTAssertEqual(actualAsset.fileExtension, expectedAsset.fileExtension, file: file, line: line)
        XCTAssertEqual(
            actualAsset.metadata.duration.bitPattern,
            expectedAsset.metadata.duration.bitPattern,
            file: file,
            line: line
        )
        XCTAssertEqual(actualAsset.metadata.codec, expectedAsset.metadata.codec, file: file, line: line)
        XCTAssertEqual(
            actualAsset.metadata.sampleRate.bitPattern,
            expectedAsset.metadata.sampleRate.bitPattern,
            file: file,
            line: line
        )
        XCTAssertEqual(actualAsset.metadata.channelCount, expectedAsset.metadata.channelCount, file: file, line: line)
    }
}
