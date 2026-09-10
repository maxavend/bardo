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

    func testLiveBufferSortsDiscoveredSegmentsAndTracksAudioProgress() {
        let recordingID = UUID()
        let buffer = TranscriptionLiveBuffer(recordingID: recordingID, audioDuration: 20)

        let later = TranscriptSegment(startTime: 8, endTime: 10, text: "Second")
        let earlier = TranscriptSegment(startTime: 2, endTime: 4, text: "First")
        let snapshot = buffer.merge([later, earlier])

        XCTAssertEqual(snapshot.recordingID, recordingID)
        XCTAssertEqual(snapshot.segments.map(\.text), ["First", "Second"])
        XCTAssertEqual(snapshot.processedAudioTime, 10)
        XCTAssertEqual(snapshot.fractionCompleted, 0.5, accuracy: 0.0001)
    }

    func testLiveBufferReplacesRevisedSegmentWithoutChangingSwiftUIIdentity() {
        let buffer = TranscriptionLiveBuffer(recordingID: UUID(), audioDuration: 30)

        let firstSnapshot = buffer.merge([
            TranscriptSegment(startTime: 1, endTime: 3, text: "Helo world")
        ])
        let firstID = firstSnapshot.segments[0].id

        let revisedSnapshot = buffer.merge([
            TranscriptSegment(startTime: 1, endTime: 3, text: "Hello world")
        ])

        XCTAssertEqual(revisedSnapshot.segments.count, 1)
        XCTAssertEqual(revisedSnapshot.segments[0].id, firstID)
        XCTAssertEqual(revisedSnapshot.segments[0].text, "Hello world")
    }

    func testLiveBufferOnlyShowsProvisionalTextUntilStableSegmentsArrive() {
        let buffer = TranscriptionLiveBuffer(recordingID: UUID(), audioDuration: 30)

        let provisional = buffer.updateProvisionalText("  Esto todavía puede cambiar  ")
        XCTAssertEqual(provisional.provisionalText, "Esto todavía puede cambiar")
        XCTAssertTrue(provisional.segments.isEmpty)

        let discovered = buffer.merge([
            TranscriptSegment(startTime: 0, endTime: 2, text: "Esto ya está estable")
        ])
        XCTAssertEqual(discovered.provisionalText, "")
        XCTAssertEqual(discovered.segments.map(\.text), ["Esto ya está estable"])

        let laterProgress = buffer.updateProvisionalText("otra hipótesis")
        XCTAssertEqual(laterProgress.provisionalText, "")
    }
}
