import XCTest
@testable import Bardo

final class WhisperIncrementalPipelineTests: XCTestCase {
    func testSixteenGigabyteProfileUsesBoundedIncrementalVADConfiguration() {
        let profile = WhisperPerformanceProfile(physicalMemory: 16 * 1_024 * 1_024 * 1_024)

        XCTAssertEqual(profile.incrementalChunkDurationSeconds, 120)
        XCTAssertEqual(profile.maxBufferedChunks, 2)
        XCTAssertEqual(profile.concurrentWorkerCount, 8)
        XCTAssertTrue(profile.usesVAD)
        XCTAssertEqual(profile.temperatureFallbackCount, 5)
    }

    func testMemoryConstrainedProfileReducesConcurrencyAndBuffering() {
        let profile = WhisperPerformanceProfile(physicalMemory: 8 * 1_024 * 1_024 * 1_024)

        XCTAssertEqual(profile.incrementalChunkDurationSeconds, 90)
        XCTAssertEqual(profile.maxBufferedChunks, 1)
        XCTAssertEqual(profile.concurrentWorkerCount, 4)
    }
}
