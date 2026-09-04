import Foundation
import XCTest
@testable import Bardo

final class TranscriptionPipelineTests: XCTestCase {
    func testBoundedAudioLoaderReadsOnlyRequestedIntervalAndConvertsTo16kMonoSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BardoBoundedAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("four-seconds.wav")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 48_000, channelCount: 2, duration: 4)
        let samples = try BoundedWhisperAudioLoader.loadSamples(from: source, startTime: 1, endTime: 2)
        XCTAssertGreaterThan(samples.count, 15_900)
        XCTAssertLessThan(samples.count, 16_100)
    }

    func testDualCaptureUsesOnlyConversationMixForTranscription() {
        let system = makeAsset(role: .systemOriginal, fileName: "system.m4a")
        let microphone = makeAsset(role: .microphoneOriginal, fileName: "microphone.m4a")
        let mix = makeAsset(role: .conversationMix, fileName: "conversation.m4a", derivedFrom: [system.id, microphone.id])
        let recording = Recording(title: "Dual", duration: 30, sources: [.systemAudio, .microphone], audioAssets: [system, microphone, mix])
        XCTAssertEqual(TranscriptionAudioSelection.candidates(for: recording).map(\.id), [mix.id])
    }

    func testDualCaptureNeverFallsBackToSingleOriginalWhenMixIsMissing() {
        let system = makeAsset(role: .systemOriginal, fileName: "system.m4a")
        let microphone = makeAsset(role: .microphoneOriginal, fileName: "microphone.m4a")
        let recording = Recording(title: "Dual without mix", duration: 30, sources: [.systemAudio, .microphone], audioAssets: [system, microphone])
        XCTAssertTrue(TranscriptionAudioSelection.candidates(for: recording).isEmpty)
    }

    private func makeAsset(role: AudioAssetRole, fileName: String, derivedFrom: [UUID] = []) -> AudioAsset {
        AudioAsset(originalFileName: fileName, fileExtension: "m4a", metadata: AudioMetadata(duration: 30, codec: "AAC", sampleRate: 48_000, channelCount: role == .systemOriginal ? 2 : 1), role: role, derivedFromAssetIDs: derivedFrom)
    }
}
