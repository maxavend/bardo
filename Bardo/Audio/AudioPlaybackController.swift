import AVFAudio
import Combine
import Foundation

struct AudioPlaybackMetadata: Equatable, Sendable {
    let title: String
    let trackLabel: String
}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var metadata: AudioPlaybackMetadata?
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var volume: Float = 1

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private var playbackEndTime: TimeInterval?

    var isLoaded: Bool {
        player != nil
    }

    @discardableResult
    func load(url: URL, metadata: AudioPlaybackMetadata? = nil) -> Bool {
        unload()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                throw AudioPlaybackError.couldNotPrepare
            }
            player.enableRate = true
            player.rate = playbackRate
            player.volume = volume
            self.player = player
            duration = player.duration
            position = player.currentTime
            self.metadata = metadata
            errorMessage = nil
            return true
        } catch {
            player = nil
            duration = 0
            position = 0
            isPlaying = false
            self.metadata = nil
            errorMessage = AudioPlaybackError.unreadableAudio(error.localizedDescription).localizedDescription
            return false
        }
    }

    func setUnavailable(_ message: String) {
        unload()
        errorMessage = message
    }

    @discardableResult
    func play() -> Bool {
        playbackEndTime = nil
        return startPlayback()
    }

    @discardableResult
    func playPreview(from startTime: TimeInterval, to endTime: TimeInterval) -> Bool {
        guard let player,
              startTime.isFinite,
              endTime.isFinite else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        let start = min(max(0, startTime), player.duration)
        let end = min(max(start, endTime), player.duration)
        guard end > start else {
            errorMessage = AudioPlaybackError.couldNotStart.localizedDescription
            return false
        }

        playbackEndTime = end
        player.currentTime = start
        position = start
        return startPlayback()
    }

    private func startPlayback() -> Bool {
        guard let player else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        if position >= player.duration || player.currentTime >= player.duration {
            player.currentTime = 0
            position = 0
        }

        guard player.play() else {
            errorMessage = AudioPlaybackError.couldNotStart.localizedDescription
            isPlaying = false
            stopProgressUpdates()
            return false
        }

        errorMessage = nil
        isPlaying = true
        startProgressUpdates()
        return true
    }

    func pause() {
        guard let player else { return }
        playbackEndTime = nil
        player.pause()
        position = player.currentTime
        isPlaying = false
        stopProgressUpdates()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            _ = play()
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = min(2, max(0.5, rate))
        playbackRate = clamped
        player?.enableRate = true
        player?.rate = clamped
    }

    func setVolume(_ value: Float) {
        let clamped = min(1, max(0, value))
        volume = clamped
        player?.volume = clamped
    }

    func seek(to time: TimeInterval) {
        guard let player else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return
        }

        let clamped = min(max(0, time), player.duration)
        playbackEndTime = nil
        player.currentTime = clamped
        position = clamped
        syncFromPlayer()
    }

    func unload() {
        stopProgressUpdates()
        playbackEndTime = nil
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
        metadata = nil
        errorMessage = nil
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.syncFromPlayer()
                if !self.isPlaying {
                    return
                }
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func syncFromPlayer() {
        guard let player else {
            isPlaying = false
            stopProgressUpdates()
            return
        }

        duration = player.duration

        if let playbackEndTime, player.currentTime >= playbackEndTime {
            player.pause()
            player.currentTime = playbackEndTime
            position = playbackEndTime
            self.playbackEndTime = nil
            isPlaying = false
            stopProgressUpdates()
            return
        }

        if isPlaying && !player.isPlaying {
            isPlaying = false
            position = player.duration
            stopProgressUpdates()
            return
        }

        position = min(max(0, player.currentTime), player.duration)
    }
}

enum AudioPlaybackError: Error, LocalizedError, Equatable, Sendable {
    case noAudioLoaded
    case couldNotPrepare
    case couldNotStart
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .noAudioLoaded:
            return "This recording has no playable managed audio."
        case .couldNotPrepare:
            return "Bardo could not prepare this audio for playback."
        case .couldNotStart:
            return "Bardo could not start audio playback."
        case .unreadableAudio(let description):
            return "The managed audio cannot be played: \(description)"
        }
    }
}
