import AVFoundation
import CoreMedia
import XCTest
@testable import Bardo

final class TranscriptTextFormatterTests: XCTestCase {
    private let you = Speaker(role: .localUser)
    private let valentina = Speaker(name: "Valentina")

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Speaker?, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, speakerID: speaker?.id, text: text)
    }

    private func transcript(_ segments: [TranscriptSegment], speakers: [Speaker]) -> Transcript {
        Transcript(
            recordingID: UUID(),
            speakers: speakers,
            segments: segments,
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "test")
        )
    }

    func testOnePersonSpeakingWithoutLongPausesIsOneBlock() {
        let formatter = TranscriptTextFormatter(title: "Revisión", localName: nil)
        let transcript = transcript([
            segment(0, 50, valentina, "Partamos por el onboarding."),
            segment(52, 130, valentina, "Bajamos de siete datos a tres."),
            segment(133, 240, valentina, "Y medimos la primera visita."),
            segment(241, 252, you, "Exacto."),
            segment(270, 280, you, "Lo vemos el jueves.")
        ], speakers: [you, valentina])

        let blocks = formatter.blocks(for: transcript)

        XCTAssertEqual(blocks.map(\.speaker), ["Valentina", String(localized: "You"), String(localized: "You")])
        XCTAssertEqual(blocks[0].start, 0)
        XCTAssertEqual(blocks[0].end, 240, "Four minutes of one voice stay together")
        XCTAssertEqual(blocks[0].text, "Partamos por el onboarding. Bajamos de siete datos a tres. Y medimos la primera visita.")
        XCTAssertEqual(blocks[1].end, 252)
        XCTAssertEqual(blocks[2].start, 270, "A long pause starts a new block")
    }

    func testTextHasTitleDateAndTimedBlocks() {
        let formatter = TranscriptTextFormatter(
            title: "Revisión",
            date: Date(timeIntervalSince1970: 1_792_000_000),
            duration: 280,
            localName: "Max"
        )
        let text = formatter.text(for: transcript([
            segment(0, 72, valentina, "Partamos."),
            segment(72, 152, you, "Exacto.")
        ], speakers: [you, valentina]))

        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Revisión")
        XCTAssertTrue(lines[1].hasSuffix("· 4:40"))
        XCTAssertEqual(Array(lines[2...]), ["", "Valentina (0:00–1:12)", "Partamos.", "", "Max (1:12–2:32)", "Exacto."])
    }

    func testWithoutSpeakersLongStretchesAreStillSplit() {
        let formatter = TranscriptTextFormatter(title: "Nota", localName: nil)
        let segments = stride(from: 0.0, to: 300, by: 30).map { segment($0, $0 + 29, nil, "Idea.") }

        let blocks = formatter.blocks(for: transcript(segments, speakers: []))

        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertTrue(blocks.allSatisfy { $0.speaker == nil && $0.end - $0.start <= 150 })
    }
}

final class MicrophoneMuteTests: XCTestCase {
    func testMutedAudioIsSilenceWithTheSameTiming() throws {
        let original = try XCTUnwrap(SyntheticAudio.buffers(seconds: 0.02, channels: 1).first)
        let mute = MicrophoneMute()
        XCTAssertTrue(mute.apply(to: original) === original, "Unmuted audio passes through")

        mute.isMuted = true
        let silenced = try XCTUnwrap(mute.apply(to: original))

        XCTAssertEqual(CMSampleBufferGetNumSamples(silenced), CMSampleBufferGetNumSamples(original))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(silenced), CMSampleBufferGetPresentationTimeStamp(original))
        XCTAssertEqual(CMSampleBufferGetDuration(silenced), CMSampleBufferGetDuration(original))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(silenced))
        var bytes = [UInt8](repeating: 1, count: CMBlockBufferGetDataLength(block))
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes), noErr)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }

    @MainActor
    func testMutedMicrophoneFileKeepsItsLength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BardoMute-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let meter = LiveAudioMeter()
        let writer = try MicrophoneFileWriter(url: url, settings: MicrophoneCaptureBackend.recordingSettings, meter: meter)

        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1) { writer.append(buffer) }
        writer.isMuted = true
        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1, startFrame: 24_000) { writer.append(buffer) }
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / 48_000, 1, accuracy: 0.03, "Silence keeps the timeline")
        XCTAssertEqual(meter.snapshot.levels.suffix(5), [0, 0, 0, 0, 0], "The live line goes flat")
    }
}

final class AudioWaveformOverviewTests: XCTestCase {
    func testOverviewFollowsLoudnessAcrossTheTimeline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BardoOverview-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        // One second of tone, then one second of silence.
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.06) * 0.3) }
        try file.write(from: buffer)

        let levels = try AudioWaveformOverview.levels(of: [PlaybackTrack(url: url)], resolution: 10)

        XCTAssertEqual(levels.count, 10)
        XCTAssertTrue(levels[0..<5].allSatisfy { $0 > 0.5 }, "\(levels)")
        XCTAssertTrue(levels[5..<10].allSatisfy { $0 == 0 }, "\(levels)")
    }
}
