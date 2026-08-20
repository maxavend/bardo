import Foundation
import XCTest
@testable import Bardo

final class TranscriptionPipelineTests: XCTestCase {
    func testLongRecordingIsPlannedAsBoundedOverlappingChunks() {
        let duration: TimeInterval = 3_600.75
        let plans = TranscriptionChunkPlanner.plans(duration: duration)

        XCTAssertGreaterThan(plans.count, 1)
        XCTAssertEqual(plans.first?.startTime, 0)
        XCTAssertEqual(plans.last?.endTime, duration)
        XCTAssertTrue(plans.allSatisfy { $0.endTime - $0.startTime <= 300.000_001 })

        for index in 0..<(plans.count - 1) {
            let current = plans[index]
            let next = plans[index + 1]
            XCTAssertEqual(current.endTime - next.startTime, 1, accuracy: 0.000_001)
            XCTAssertEqual(current.acceptanceEnd, next.acceptanceStart, accuracy: 0.000_001)
        }
    }

    func testShortRecordingUsesSingleChunkWithoutArtificialPadding() {
        let plans = TranscriptionChunkPlanner.plans(duration: 42.5)

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].startTime, 0)
        XCTAssertEqual(plans[0].endTime, 42.5)
        XCTAssertEqual(plans[0].acceptanceStart, 0)
        XCTAssertEqual(plans[0].acceptanceEnd, 42.5)
        XCTAssertTrue(plans[0].isLast)
    }

    func testInvalidDurationsAndBoundsDoNotProduceWork() {
        XCTAssertTrue(TranscriptionChunkPlanner.plans(duration: 0).isEmpty)
        XCTAssertTrue(TranscriptionChunkPlanner.plans(duration: -.infinity).isEmpty)
        XCTAssertTrue(TranscriptionChunkPlanner.plans(duration: .infinity).isEmpty)
        XCTAssertTrue(TranscriptionChunkPlanner.plans(duration: .nan).isEmpty)
        XCTAssertTrue(
            TranscriptionChunkPlanner.plans(
                duration: 10,
                chunkDuration: .infinity,
                overlap: 1
            ).isEmpty
        )
        XCTAssertTrue(
            TranscriptionChunkPlanner.plans(
                duration: 10,
                chunkDuration: 1,
                overlap: 1
            ).isEmpty
        )
        XCTAssertTrue(
            TranscriptionChunkPlanner.plans(
                duration: 10,
                chunkDuration: 5,
                overlap: .nan
            ).isEmpty
        )
    }

    func testBoundedAudioLoaderReadsOnlyRequestedIntervalAndConvertsTo16kMonoSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoBoundedAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("four-seconds.wav")
        try AudioTestFixture.makeWAV(
            at: source,
            sampleRate: 48_000,
            channelCount: 2,
            duration: 4
        )

        let samples = try BoundedWhisperAudioLoader.loadSamples(
            from: source,
            startTime: 1,
            endTime: 2
        )

        XCTAssertGreaterThan(samples.count, 15_900)
        XCTAssertLessThan(samples.count, 16_100)
        XCTAssertLessThan(samples.count, 20_000, "The loader must not retain the four-second source when only one second is requested")
    }

    func testDualCaptureUsesOnlyConversationMixForTranscription() {
        let system = makeAsset(role: .systemOriginal, fileName: "system.m4a")
        let microphone = makeAsset(role: .microphoneOriginal, fileName: "microphone.m4a")
        let mix = makeAsset(
            role: .conversationMix,
            fileName: "conversation.m4a",
            derivedFrom: [system.id, microphone.id]
        )
        let recording = Recording(
            title: "Dual",
            duration: 30,
            sources: [.systemAudio, .microphone],
            audioAssets: [system, microphone, mix]
        )

        XCTAssertEqual(TranscriptionAudioSelection.candidates(for: recording).map(\.id), [mix.id])
    }

    func testDualCaptureNeverSilentlyFallsBackToSingleOriginalWhenMixIsMissing() {
        let system = makeAsset(role: .systemOriginal, fileName: "system.m4a")
        let microphone = makeAsset(role: .microphoneOriginal, fileName: "microphone.m4a")
        let recording = Recording(
            title: "Dual without mix",
            duration: 30,
            sources: [.systemAudio, .microphone],
            audioAssets: [system, microphone]
        )

        XCTAssertTrue(TranscriptionAudioSelection.candidates(for: recording).isEmpty)
    }

    private func makeAsset(
        role: AudioAssetRole,
        fileName: String,
        derivedFrom: [UUID] = []
    ) -> AudioAsset {
        AudioAsset(
            originalFileName: fileName,
            fileExtension: "m4a",
            metadata: AudioMetadata(
                duration: 30,
                codec: "AAC",
                sampleRate: 48_000,
                channelCount: role == .systemOriginal ? 2 : 1
            ),
            role: role,
            derivedFromAssetIDs: derivedFrom
        )
    }
}
