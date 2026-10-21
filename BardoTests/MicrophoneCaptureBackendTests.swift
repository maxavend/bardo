import AudioToolbox
import AVFAudio
import XCTest

@testable import Bardo

final class MicrophoneCaptureBackendTests: XCTestCase {
    @MainActor
    func testProductionRecorderStagesCrashSafeLinearPCM() {
        let settings = MicrophoneCaptureBackend.recordingSettings

        XCTAssertEqual(MicrophoneCaptureBackend.recordingFileExtension, "caf")
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
    }

    @MainActor
    func testWriterRecordsMicrophoneBuffersExceptWhilePaused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BardoMicrophone-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MicrophoneFileWriter(url: url, settings: MicrophoneCaptureBackend.recordingSettings)

        for buffer in SyntheticAudio.buffers(seconds: 1, channels: 1) {
            writer.append(buffer)
        }
        XCTAssertEqual(writer.duration, 1, accuracy: 0.03)
        XCTAssertGreaterThan(writer.level, 0.5, "A -14 dBFS tone shows on the meter")

        writer.isPaused = true
        XCTAssertEqual(writer.level, 0)
        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1, startFrame: 48_000) {
            writer.append(buffer)
        }
        writer.isPaused = false
        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1, startFrame: 72_000) {
            writer.append(buffer)
        }
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(Double(file.length) / 48_000, 1.5, accuracy: 0.03)
        XCTAssertEqual(writer.duration, 1.5, accuracy: 0.03)
    }
}
