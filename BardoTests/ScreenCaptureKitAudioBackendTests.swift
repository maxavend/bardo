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
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
    }

    func testDualConfigurationUsesSameStreamMicrophoneOutput() {
        let configuration = ScreenCaptureKitAudioBackend.makeConfiguration(includeMicrophone: true)

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
    }
}
