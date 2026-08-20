import AVFAudio
import Foundation
import XCTest

@testable import Bardo

enum AudioTestFixture {
    static func makeWAV(
        at url: URL,
        sampleRate: Double = 8_000,
        channelCount: AVAudioChannelCount = 1,
        duration: TimeInterval = 0.5
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            throw XCTSkip("Could not create an AVAudioFormat fixture.")
        }

        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
        let buffer = try makeBuffer(format: format, frameCount: frameCount)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }

    static func makeM4A(
        at url: URL,
        sampleRate: Double = 48_000,
        channelCount: AVAudioChannelCount = 1,
        duration: TimeInterval = 0.5
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            throw XCTSkip("Could not create an AVAudioFormat fixture.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
        let buffer = try makeBuffer(format: format, frameCount: frameCount)
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
        file.close()
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw XCTSkip("Could not allocate an audio fixture buffer.")
        }

        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = Float(
                    sin(Double(frame) * 2 * .pi * 440 / format.sampleRate) * 0.1
                )
            }
        }
        return buffer
    }
}
