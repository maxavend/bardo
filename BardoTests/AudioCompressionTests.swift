import AVFAudio
import Foundation
import XCTest
@testable import Bardo

final class AudioCompressionTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bardo-compression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    // MARK: Plan

    private func asset(duration: TimeInterval, channels: UInt32 = 1) -> AudioAsset {
        AudioAsset(
            originalFileName: "audio.wav",
            fileExtension: "wav",
            metadata: AudioMetadata(duration: duration, codec: "Linear PCM", sampleRate: 48_000, channelCount: channels)
        )
    }

    func testPlanEstimatesHeavyAudioAndKeepsLightAudioAsItIs() {
        // Ten minutes of mono WAV at 48 kHz: about 57.6 MB, far above Equilibrada's AAC.
        let heavy = asset(duration: 600)
        // The same length already at 20 kbps Opus: Equilibrada would not shrink it.
        let light = asset(duration: 600)
        let heavyRecording = Recording(title: "WAV", duration: 600, sources: [.importedFile], audioAssets: [heavy])
        let lightRecording = Recording(title: "Opus", duration: 600, sources: [.importedFile], audioAssets: [light])
        let sizes: [AudioAsset.ID: Int64] = [heavy.id: 57_600_000, light.id: 1_500_000]

        let plan = AudioCompressionPlan(recordings: [heavyRecording, lightRecording], audioBytes: sizes)

        // Equilibrada mono: 24 kbps, 1.8 MB in ten minutes.
        XCTAssertEqual(plan.currentBytes, 59_100_000)
        XCTAssertEqual(plan.estimatedBytes, 1_800_000 + 1_500_000)
        XCTAssertEqual(plan.savedBytes, 55_800_000)
        XCTAssertEqual(plan.shrinkingRecordingIDs, [heavyRecording.id])
        XCTAssertTrue(plan.savesSpace)
    }

    func testPlanSavesNothingWhenEveryTrackIsAlreadySmall() {
        let light = asset(duration: 600)
        let recording = Recording(title: "Opus", duration: 600, sources: [.importedFile], audioAssets: [light])

        let plan = AudioCompressionPlan(
            recordings: [recording],
            audioBytes: [light.id: 1_500_000],
            encoding: .init(bitRate: .kbps48)
        )

        XCTAssertFalse(plan.savesSpace)
        XCTAssertEqual(plan.estimatedBytes, plan.currentBytes)
    }

    // MARK: Excerpt

    func testExcerptStartsAQuarterInAndAlwaysFits() {
        XCTAssertEqual(AudioExcerpt.start(forDuration: 10), 0)
        XCTAssertEqual(AudioExcerpt.start(forDuration: 200), 50)
        XCTAssertEqual(AudioExcerpt.start(forDuration: 24), 4)
    }

    func testExcerptKeepsTheRequestedStretchUncompressed() throws {
        let source = rootURL.appendingPathComponent("source.wav")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 16_000, channelCount: 1, duration: 3)
        let excerpt = rootURL.appendingPathComponent("excerpt.caf")

        let length = try AudioExcerpt.write(from: source, start: 1, length: 1.5, to: excerpt)

        let file = try AVAudioFile(forReading: excerpt)
        XCTAssertEqual(length, 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
    }

    func testExcerptEndsWithTheRecording() throws {
        let source = rootURL.appendingPathComponent("short.wav")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 16_000, channelCount: 1, duration: 2)

        let length = try AudioExcerpt.write(
            from: source,
            start: 1.5,
            length: 20,
            to: rootURL.appendingPathComponent("tail.caf")
        )

        XCTAssertEqual(length, 0.5, accuracy: 0.001)
    }

    // MARK: Compressing several conversations

    @MainActor
    func testCompressingSeveralConversationsReplacesOnlyWhatShrinks() async throws {
        let store = RecordingStore(rootURL: rootURL.appendingPathComponent("Library"))
        let importer = AudioImportService(store: store)

        let wav = rootURL.appendingPathComponent("Meeting.wav")
        try AudioTestFixture.makeWAV(at: wav, sampleRate: 48_000, channelCount: 1, duration: 4)
        // Already AAC at Compacta: Equilibrada would not save a fifth of it.
        let compact = rootURL.appendingPathComponent("Voice note.m4a")
        try AudioFileTranscoder.encode(from: wav, to: compact) { _ in
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant
            ]
        }
        let heavy = try await importer.importFile(at: wav)
        let light = try await importer.importFile(at: compact)

        let model = LibraryViewModel(store: store)
        await model.reload()
        let before = await model.storageReport()

        await model.compressAudio([heavy.id, light.id], using: .init(bitRate: .kbps48))

        let run = try XCTUnwrap(model.compressionRun)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.completed, 2)
        XCTAssertTrue(run.failures.isEmpty)
        XCTAssertGreaterThan(run.savedBytes, 0)

        let compressed = try XCTUnwrap(model.recordings.first { $0.id == heavy.id }?.audioAssets.first)
        XCTAssertEqual(compressed.fileExtension, "m4a")
        XCTAssertEqual(compressed.originalFileName, "Meeting.m4a")
        let untouched = try XCTUnwrap(model.recordings.first { $0.id == light.id }?.audioAssets.first)
        XCTAssertEqual(untouched, light.audioAssets.first)

        let after = await model.storageReport()
        XCTAssertEqual(before.audioBytes - after.audioBytes, run.savedBytes)
        XCTAssertNil(model.compressingRecordingID)
    }

    @MainActor
    func testStorageReportMeasuresEachConversation() async throws {
        let store = RecordingStore(rootURL: rootURL.appendingPathComponent("Library"))
        let source = rootURL.appendingPathComponent("Meeting.wav")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 16_000, channelCount: 1, duration: 1)
        let recording = try await AudioImportService(store: store).importFile(at: source)
        let model = LibraryViewModel(store: store)
        await model.reload()

        let report = await model.storageReport(for: [recording.id])
        let entry = try XCTUnwrap(report.entries[recording.id])
        let assetID = try XCTUnwrap(recording.audioAssets.first?.id)

        XCTAssertEqual(entry.audioBytes[assetID], LibraryStorage.fileSize(source))
        XCTAssertGreaterThan(entry.totalBytes, entry.audioTotal)
    }
}
