import AVFoundation
import Foundation
import XCTest
@testable import Bardo

final class ScreenCaptureKitAudioBackendTests: XCTestCase {
    func testSystemOnlyConfigurationUsesAudioAndExcludesBardoPlayback() {
        let configuration = ScreenCaptureKitAudioBackend.makeConfiguration(includeMicrophone: false)

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertFalse(configuration.captureMicrophone)
        XCTAssertNil(configuration.microphoneCaptureDeviceID)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
    }

    func testDualConfigurationUsesSameStreamMicrophoneOutputAndDefaultDevice() {
        let configuration = ScreenCaptureKitAudioBackend.makeConfiguration(includeMicrophone: true)

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(
            configuration.microphoneCaptureDeviceID,
            AVCaptureDevice.default(for: .audio)?.uniqueID
        )
    }
}
