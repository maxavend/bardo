import AVFoundation
import XCTest
@testable import Bardo

final class FullPlayerTests: XCTestCase {
    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("BardoFullPlayer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL { try? FileManager.default.removeItem(at: baseURL) }
    }

    /// Writes tone and silence: `pattern` lists (seconds, isTone).
    private func makeAudio(_ pattern: [(TimeInterval, Bool)]) throws -> URL {
        let url = baseURL.appendingPathComponent("\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for (seconds, isTone) in pattern {
            let frames = AVAudioFrameCount(seconds * 16_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] = isTone ? Float(sin(Double(frame) * 0.2) * 0.3) : 0
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testOnlyLongSilencesAreSkippedAndSpeechIsNeverClipped() throws {
        let url = try makeAudio([(1, true), (3, false), (1, true), (1, false), (1, true)])

        let ranges = try AudioWaveformOverview.silentRanges(of: [PlaybackTrack(url: url)])

        XCTAssertEqual(ranges.count, 1, "A one-second pause is kept: \(ranges)")
        let range = try XCTUnwrap(ranges.first)
        XCTAssertEqual(range.lowerBound, 1.3, accuracy: 0.11, "Skipping starts a margin after the speech")
        XCTAssertEqual(range.upperBound, 3.7, accuracy: 0.11, "and ends a margin before it resumes")
    }

    func testSkippingSilencesIsSavedWithTheRecording() throws {
        let recording = Recording(title: "Nota", sources: [.microphone], skipsSilences: true)

        let manifest = RecordingManifestV3(recording: recording)
        let roundTrip = try JSONDecoder().decode(RecordingManifestV3.self, from: JSONEncoder().encode(manifest))

        XCTAssertTrue(roundTrip.recording.skipsSilences)
        let plain = RecordingManifestV3(recording: Recording(title: "Otra", sources: [.microphone]))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("skipsSilences"), "Manifests without the option stay as they were")
        XCTAssertFalse(json.contains("notes"))
    }
}
