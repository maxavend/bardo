import Foundation
import XCTest
@testable import Bardo

final class ConversationMixServiceTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoConversationMix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testRealAVFoundationMixPreservesOffsetAndProducesPlayableM4A() async throws {
        let systemURL = rootURL.appendingPathComponent("system.m4a")
        let microphoneURL = rootURL.appendingPathComponent("microphone.m4a")
        let outputURL = rootURL.appendingPathComponent("mix.m4a")
        try AudioTestFixture.makeM4A(at: systemURL, channelCount: 2, duration: 0.45)
        try AudioTestFixture.makeM4A(at: microphoneURL, channelCount: 1, duration: 0.35)

        let metadata = try await AVFoundationConversationMixer().makeMix(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            systemOffset: 0,
            microphoneOffset: 0.10,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: outputURL).count, 0)
        XCTAssertGreaterThan(metadata.duration, 0.40)
        XCTAssertLessThan(metadata.duration, 0.70)
        XCTAssertGreaterThan(metadata.sampleRate, 0)
        XCTAssertGreaterThan(metadata.channelCount, 0)

        let playback = await AudioPlaybackController()
        let loaded = await playback.load(url: outputURL)
        XCTAssertTrue(loaded)
        let isLoaded = await playback.isLoaded
        XCTAssertTrue(isLoaded)
    }
}
