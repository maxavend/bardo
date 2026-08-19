import AudioToolbox
import AVFAudio
import XCTest

@testable import Bardo

final class AVAudioRecorderCaptureBackendTests: XCTestCase {
    @MainActor
    func testProductionRecorderUsesCompactNativeConversationFormat() {
        let settings = AVAudioRecorderCaptureBackend.recordingSettings

        XCTAssertEqual(AVAudioRecorderCaptureBackend.recordingFileExtension, "m4a")
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings[AVEncoderAudioQualityKey] as? Int, AVAudioQuality.high.rawValue)
    }
}
