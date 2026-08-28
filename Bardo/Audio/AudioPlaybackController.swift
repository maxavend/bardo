import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioPlaybackTimeline: ObservableObject {
    @Published fileprivate(set) var position: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0
}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    /// Timeline ticks at 10 Hz while audio is playing. Keeping them in a dedicated observable
    /// prevents the recording detail, transcript rows, toolbar and inspector from being
    /// invalidated on every playback tick. Only the compact player observes this object.
    let timeline = AudioPlaybackTimeline()

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    var position: TimeInterval { timeline.position }
    var duration: TimeInterval { timeline.duration }

    var isLoaded: Bool {
        player != nil
    }

    @discardableResult
    func load(url: URL) -> Bool {
        unload()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else {
                throw AudioPlaybackError.couldNotPrepare
            }
            self.player = player
            updateTimeline(position: player.currentTime, duration: player.duration)
            errorMessage = nil
            return true
        } catch {
            player = nil
            updateTimeline(position: 0, duration: 0)
            isPlaying = false
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
        guard let player else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        if timeline.position >= player.duration || player.currentTime >= player.duration {
            player.currentTime = 0
            updateTimeline(position: 0, duration: player.duration)
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
        updateTimeline(position: player.currentTime, duration: player.duration)
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
        updateTimeline(position: clamped, duration: player.duration)
        syncFromPlayer()
    }

    func unload() {
        stopProgressUpdates()
        player?.stop()
        player = nil
        isPlaying = false
        updateTimeline(position: 0, duration: 0)
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

        if isPlaying && !player.isPlaying {
            updateTimeline(position: player.duration, duration: player.duration)
            isPlaying = false
            stopProgressUpdates()
            return
        }

        updateTimeline(
            position: min(max(0, player.currentTime), player.duration),
            duration: player.duration
        )
    }

    private func updateTimeline(position: TimeInterval, duration: TimeInterval) {
        if timeline.duration != duration {
            timeline.duration = duration
        }
        if timeline.position != position {
            timeline.position = position
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
