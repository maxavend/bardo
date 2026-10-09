import AudioToolbox
import AVFAudio
import XCTest

@testable import Bardo

final class AVAudioRecorderCaptureBackendTests: XCTestCase {
    @MainActor
    func testProductionRecorderStagesCrashSafeLinearPCM() {
        let settings = AVAudioRecorderCaptureBackend.recordingSettings

        XCTAssertEqual(AVAudioRecorderCaptureBackend.recordingFileExtension, "caf")
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
    }
}
