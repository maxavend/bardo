import Foundation
import WhisperKit

enum BoundedWhisperAudioLoader {
    static func loadSamples(
        from audioURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) throws -> [Float] {
        let buffer = try AudioProcessor.loadAudio(
            fromPath: audioURL.path,
            channelMode: .sumChannels(nil),
            startTime: startTime,
            endTime: endTime
        )
        return AudioProcessor.convertBufferToArray(buffer: buffer)
    }
}
