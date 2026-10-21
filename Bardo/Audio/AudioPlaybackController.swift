import AVFAudio
import Combine
import Foundation

struct AudioPlaybackMetadata: Equatable, Sendable {
    let title: String
    let trackLabel: String
}

/// One file to play and where it starts on the recording's timeline.
struct PlaybackTrack: Hashable, Sendable {
    let url: URL
    var offset: TimeInterval = 0
    var source: TranscriptSource? = nil
}

/// Which voices of a recording with separate tracks are heard.
enum PlaybackFocus: String, CaseIterable, Identifiable, Sendable {
    case everyone
    case microphone
    case system

    var id: String { rawValue }

    func includes(_ source: TranscriptSource?) -> Bool {
        switch (self, source) {
        case (.everyone, _), (_, nil): true
        case (.microphone, .microphone), (.system, .system): true
        default: false
        }
    }
}

/// Plays a recording's audio: one file, or the microphone and the Mac's audio as
/// separate tracks kept in step on the recording's timeline, so either can be heard
/// alone or balanced against the other.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var metadata: AudioPlaybackMetadata?
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var volume: Float = 1
    @Published private(set) var focus: PlaybackFocus = .everyone
    @Published private(set) var microphoneGain: Float = 1
    @Published private(set) var systemGain: Float = 1

    private struct LoadedTrack {
        let player: AVAudioPlayer
        let track: PlaybackTrack
    }

    private var tracks: [LoadedTrack] = []
    private var progressTask: Task<Void, Never>?
    private var playbackEndTime: TimeInterval?

    var isLoaded: Bool {
        !tracks.isEmpty
    }

    /// Stretches of the timeline playback jumps over, such as long silences.
    var skippedRanges: [ClosedRange<TimeInterval>] = []

    /// The files on the timeline, for drawing the recording's waveform.
    var loadedTracks: [PlaybackTrack] {
        tracks.map(\.track)
    }

    /// Whether the microphone and the Mac's audio can be heard apart.
    var hasSeparateTracks: Bool {
        tracks.contains { $0.track.source == .microphone } && tracks.contains { $0.track.source == .system }
    }

    /// Loads `url` for playback. Loading the file that is already loaded keeps its
    /// position and playback state, so refreshing the Library never interrupts listening.
    @discardableResult
    func load(url: URL, metadata: AudioPlaybackMetadata? = nil) -> Bool {
        load(tracks: [PlaybackTrack(url: url)], metadata: metadata)
    }

    /// Loads one or more tracks that play together on one timeline. Loading the tracks
    /// that are already loaded keeps their position and playback state.
    @discardableResult
    func load(tracks newTracks: [PlaybackTrack], metadata: AudioPlaybackMetadata? = nil) -> Bool {
        if !tracks.isEmpty, tracks.map(\.track.normalized) == newTracks.map(\.normalized) {
            if let metadata { self.metadata = metadata }
            errorMessage = nil
            return true
        }
        unload()

        do {
            guard !newTracks.isEmpty else { throw AudioPlaybackError.noAudioLoaded }
            tracks = try newTracks.map { track in
                let player = try AVAudioPlayer(contentsOf: track.url)
                guard player.prepareToPlay() else {
                    throw AudioPlaybackError.couldNotPrepare
                }
                player.enableRate = true
                player.rate = playbackRate
                return LoadedTrack(player: player, track: track)
            }
            applyVolumes()
            duration = timelineDuration
            position = 0
            self.metadata = metadata
            errorMessage = nil
            return true
        } catch {
            tracks = []
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
        guard isLoaded,
              startTime.isFinite,
              endTime.isFinite else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        let start = min(max(0, startTime), duration)
        let end = min(max(start, endTime), duration)
        guard end > start else {
            errorMessage = AudioPlaybackError.couldNotStart.localizedDescription
            return false
        }

        pausePlayers()
        playbackEndTime = end
        position = start
        return startPlayback()
    }

    private func startPlayback() -> Bool {
        guard isLoaded else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return false
        }

        if position >= duration {
            position = 0
        }

        guard startPlayers() else {
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

    /// Starts every track at `position`. Separate tracks start on the same audio clock
    /// instant, a track that begins later on the timeline waits for its moment, and one
    /// that already ended stays silent.
    private func startPlayers() -> Bool {
        guard let clock = tracks.first?.player else { return false }
        if tracks.count == 1 {
            let player = clock
            player.currentTime = min(max(0, position), player.duration)
            return player.play()
        }

        let startTime = clock.deviceCurrentTime + 0.05
        var started = false
        for loaded in tracks {
            let localTime = position - loaded.track.offset
            guard localTime < loaded.player.duration else { continue }
            loaded.player.currentTime = max(0, localTime)
            let delay = localTime < 0 ? -localTime / Double(playbackRate) : 0
            started = loaded.player.play(atTime: startTime + delay) || started
        }
        return started
    }

    func pause() {
        guard isLoaded else { return }
        playbackEndTime = nil
        position = currentTimelinePosition
        pausePlayers()
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
        for loaded in tracks {
            loaded.player.enableRate = true
            loaded.player.rate = clamped
        }
    }

    func setVolume(_ value: Float) {
        volume = min(1, max(0, value))
        applyVolumes()
    }

    func setFocus(_ focus: PlaybackFocus) {
        self.focus = focus
        applyVolumes()
    }

    func setGain(_ value: Float, for source: TranscriptSource) {
        let clamped = min(1, max(0, value))
        switch source {
        case .microphone: microphoneGain = clamped
        case .system: systemGain = clamped
        }
        applyVolumes()
    }

    func seek(to time: TimeInterval) {
        guard isLoaded else {
            errorMessage = AudioPlaybackError.noAudioLoaded.localizedDescription
            return
        }

        let clamped = min(max(0, time), duration)
        playbackEndTime = nil
        position = clamped
        if isPlaying && tracks.count > 1 {
            // Restart together so the tracks stay in step after the jump.
            pausePlayers()
            _ = startPlayers()
        } else {
            for loaded in tracks {
                loaded.player.currentTime = min(max(0, clamped - loaded.track.offset), loaded.player.duration)
            }
        }
        syncFromPlayer()
    }

    func unload() {
        stopProgressUpdates()
        playbackEndTime = nil
        for loaded in tracks {
            loaded.player.stop()
        }
        tracks = []
        isPlaying = false
        position = 0
        duration = 0
        metadata = nil
        errorMessage = nil
    }

    private func pausePlayers() {
        for loaded in tracks {
            loaded.player.pause()
        }
    }

    private func applyVolumes() {
        for loaded in tracks {
            let source = loaded.track.source
            let gain: Float = switch source {
            case .microphone: microphoneGain
            case .system: systemGain
            case nil: 1
            }
            loaded.player.volume = focus.includes(source) ? volume * gain : 0
        }
    }

    private var timelineDuration: TimeInterval {
        tracks.map { $0.track.offset + $0.player.duration }.max() ?? 0
    }

    /// Where playback is on the timeline: the furthest point any playing track reached.
    private var currentTimelinePosition: TimeInterval {
        let playing = tracks.filter(\.player.isPlaying)
        guard !playing.isEmpty else { return position }
        return playing.map { $0.track.offset + $0.player.currentTime }.max() ?? position
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
        guard isLoaded else {
            isPlaying = false
            stopProgressUpdates()
            return
        }

        duration = timelineDuration
        let current = currentTimelinePosition

        if isPlaying, let skipped = skippedRanges.first(where: { $0.contains(current) }), skipped.upperBound < duration {
            seek(to: skipped.upperBound)
            return
        }

        if let playbackEndTime, isPlaying, current >= playbackEndTime {
            pausePlayers()
            position = playbackEndTime
            self.playbackEndTime = nil
            isPlaying = false
            stopProgressUpdates()
            return
        }

        if isPlaying && !tracks.contains(where: \.player.isPlaying) {
            isPlaying = false
            position = duration
            stopProgressUpdates()
            return
        }

        position = min(max(0, current), duration)
    }
}

private extension PlaybackTrack {
    var normalized: PlaybackTrack {
        PlaybackTrack(url: url.standardizedFileURL, offset: offset, source: source)
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
            return String(localized: "This recording has no playable managed audio.")
        case .couldNotPrepare:
            return String(localized: "Bardo could not prepare this audio for playback.")
        case .couldNotStart:
            return String(localized: "Bardo could not start audio playback.")
        case .unreadableAudio(let description):
            return String(localized: "The managed audio cannot be played: \(description)")
        }
    }
}
