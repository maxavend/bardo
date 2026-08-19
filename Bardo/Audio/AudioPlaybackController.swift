import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    var isLoaded: Bool {
        player != nil
    }

    func load(url: URL) {
        unload()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                throw AudioPlaybackError.couldNotPrepare
            }
            self.player = player
            duration = player.duration
            position = player.currentTime
            errorMessage = nil
        } catch {
            player = nil
            duration = 0
            position = 0
            isPlaying = false
            errorMessage = AudioPlaybackError.unreadableAudio(error.localizedDescription).localizedDescription
        }
    }

    func setUnavailable(_ message: String) {
        unload()
        errorMessage = message
    }

    @discardableResult
    func play() -> Bool {
        guard let player else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        if player.currentTime >= player.duration {
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

    func seek(to time: TimeInterval) {
        guard let player else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return
        }

        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        position = clamped
        syncFromPlayer()
    }

    func unload() {
        stopProgressUpdates()
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
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

        position = min(max(0, player.currentTime), player.duration)
        duration = player.duration

        if isPlaying && !player.isPlaying {
            isPlaying = false
            if player.currentTime >= player.duration - 0.05 {
                position = player.duration
            }
            stopProgressUpdates()
        }
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
