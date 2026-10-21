import Accelerate
import AVFAudio
import Combine
import Foundation

/// The loudness of a whole recording, as evenly spaced levels from 0 to 1 on the live
/// meter's decibel scale, for the overview a person scrubs through.
enum AudioWaveformOverview {
    /// Enough levels for the widest window; views draw fewer by taking the loudest.
    static let resolution = 600

    /// Reads every track and keeps, for each slice of the timeline, its loudest track.
    static func levels(of tracks: [PlaybackTrack], resolution: Int = resolution) throws -> [Float] {
        let files = try tracks.map { (track: $0, file: try AVAudioFile(forReading: $0.url)) }
        let duration = files.map { $0.track.offset + Double($0.file.length) / $0.file.processingFormat.sampleRate }.max() ?? 0
        guard duration > 0, resolution > 0 else { return [] }

        var squares = [Double](repeating: 0, count: resolution)
        var counts = [Int](repeating: 0, count: resolution)
        var result = [Float](repeating: 0, count: resolution)
        for (track, file) in files {
            squares = [Double](repeating: 0, count: resolution)
            counts = [Int](repeating: 0, count: resolution)
            let format = file.processingFormat
            let chunk: AVAudioFrameCount = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { continue }
            let channelCount = Int(format.channelCount)
            var mono = [Float](repeating: 0, count: Int(chunk))
            var frame: AVAudioFramePosition = 0
            while frame < file.length {
                try file.read(into: buffer, frameCount: chunk)
                let length = Int(buffer.frameLength)
                guard length > 0, let channels = buffer.floatChannelData else { break }
                // Fold the channels into one, then sum each slice's squares at once.
                mono.withUnsafeMutableBufferPointer { mono in
                    let output = mono.baseAddress!
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(channels[0], 1, &scale, output, 1, vDSP_Length(length))
                    for channel in 1..<max(1, channelCount) {
                        vDSP_vsma(channels[channel], 1, &scale, output, 1, output, 1, vDSP_Length(length))
                    }
                    var index = 0
                    while index < length {
                        let time = track.offset + Double(frame + AVAudioFramePosition(index)) / format.sampleRate
                        let slot = min(resolution - 1, max(0, Int(time / duration * Double(resolution))))
                        let slotEnd = (Double(slot + 1) / Double(resolution) * duration - track.offset) * format.sampleRate
                        let end = slot == resolution - 1
                            ? length
                            : min(length, max(index + 1, Int(slotEnd.rounded(.up)) - Int(frame)))
                        var sum: Float = 0
                        vDSP_svesq(output + index, 1, &sum, vDSP_Length(end - index))
                        squares[slot] += Double(sum)
                        counts[slot] += end - index
                        index = end
                    }
                }
                frame += AVAudioFramePosition(length)
            }
            for slot in 0..<resolution where counts[slot] > 0 {
                let level = LiveAudioMeter.level(meanSquare: Float(squares[slot] / Double(counts[slot])))
                result[slot] = max(result[slot], level)
            }
        }
        return result
    }
}

/// Loads a recording's overview off the main thread and remembers it for the session.
@MainActor
final class AudioWaveformOverviewModel: ObservableObject {
    @Published private(set) var levels: [Float]?

    private static var cache: [[PlaybackTrack]: [Float]] = [:]
    private var loadedTracks: [PlaybackTrack] = []
    private var task: Task<Void, Never>?

    func load(_ tracks: [PlaybackTrack]) {
        guard tracks != loadedTracks else { return }
        loadedTracks = tracks
        task?.cancel()
        guard !tracks.isEmpty else {
            levels = nil
            return
        }
        if let cached = Self.cache[tracks] {
            levels = cached
            return
        }
        levels = nil
        task = Task { [weak self] in
            let levels = await Task.detached(priority: .utility) {
                try? AudioWaveformOverview.levels(of: tracks)
            }.value
            guard !Task.isCancelled, let self, self.loadedTracks == tracks, let levels else { return }
            Self.cache[tracks] = levels
            self.levels = levels
        }
    }
}
