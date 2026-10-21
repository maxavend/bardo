import CoreAudio
import XCTest
@testable import Bardo

final class AudioDeviceSelectionTests: XCTestCase {
    private let speakerMicrophone = AudioDevice(uid: "08-EB-ED-1E-98-B1:input", name: "Mi Portable BT Speaker 16W", transport: .bluetooth)
    private let speakerOutput = AudioDevice(uid: "08-EB-ED-1E-98-B1:output", name: "Mi Portable BT Speaker 16W", transport: .bluetooth)
    private let builtInMicrophone = AudioDevice(uid: "BuiltInMicrophoneDevice", name: "Micrófono del MacBook Air", transport: .builtIn)
    private let builtInSpeakers = AudioDevice(uid: "BuiltInSpeakerDevice", name: "Altavoces del MacBook Air", transport: .builtIn)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "BardoAudioDeviceSelectionTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testChosenDevicesAreRememberedAndCleared() {
        let preferences = AudioDevicePreferences(defaults: defaults)
        XCTAssertNil(preferences.inputDeviceUID, "Recordings follow the macOS default until a device is chosen")
        XCTAssertNil(preferences.outputDeviceUID)

        preferences.setDevice(builtInMicrophone, for: .input)
        preferences.setDevice(builtInSpeakers, for: .output)

        let relaunched = AudioDevicePreferences(defaults: defaults)
        XCTAssertEqual(relaunched.inputDeviceUID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(relaunched.inputDeviceName, "Micrófono del MacBook Air")
        XCTAssertEqual(relaunched.outputDeviceUID, "BuiltInSpeakerDevice")

        relaunched.setDevice(nil, for: .input)
        XCTAssertNil(relaunched.inputDeviceUID)
        XCTAssertNil(relaunched.inputDeviceName)
        XCTAssertEqual(relaunched.outputDeviceUID, "BuiltInSpeakerDevice", "Each direction is remembered on its own")
    }

    func testDisconnectedChoiceFallsBackToTheDefault() {
        let connected = [speakerMicrophone, builtInMicrophone]

        XCTAssertEqual(AudioDevicePreferences.resolve(preferredUID: builtInMicrophone.uid, among: connected), builtInMicrophone)
        XCTAssertNil(AudioDevicePreferences.resolve(preferredUID: "USB-Headset", among: connected))
        XCTAssertNil(AudioDevicePreferences.resolve(preferredUID: nil, among: connected))
    }

    func testBluetoothMicrophoneWarnsAboutHandsFreeMode() {
        XCTAssertEqual(HandsFreeRisk(input: speakerMicrophone, output: speakerOutput), .microphoneAndOutput)
        XCTAssertEqual(HandsFreeRisk(input: speakerMicrophone, output: builtInSpeakers), .microphone)
        XCTAssertEqual(HandsFreeRisk(input: speakerMicrophone, output: nil), .microphone)
        XCTAssertNil(HandsFreeRisk(input: builtInMicrophone, output: speakerOutput))
        XCTAssertNil(HandsFreeRisk(input: nil, output: speakerOutput))
    }

    func testMenusNameTheConnectionWhereTheNameDoesNot() {
        XCTAssertEqual(speakerMicrophone.menuTitle, "Mi Portable BT Speaker 16W (Bluetooth)")
        XCTAssertEqual(builtInMicrophone.menuTitle, "Micrófono del MacBook Air")
        XCTAssertEqual(AudioDeviceTransport(coreAudioValue: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioDeviceTransport(coreAudioValue: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioDeviceTransport(coreAudioValue: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioDeviceTransport(coreAudioValue: kAudioDeviceTransportTypeContinuityCaptureWireless), .iPhone)
    }
}
