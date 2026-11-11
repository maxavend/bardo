@preconcurrency import AVFAudio
import Foundation

/// Plays a short excerpt of a conversation as it is and as it would sound compressed.
/// Both versions play together, in step, and only the chosen one is heard, so switching
/// between them never jumps or pauses: the difference is all that changes.
@MainActor
final class CompressionPreviewPlayer: ObservableObject {
    enum Version: Hashable {
        case original
        case compressed
    }

    enum State: Equatable {
        case idle
        case preparing
        case ready
        case unavailable
    }

    @Published private(set) var state: State = .idle
    @Published var version: Version = .compressed {
        didSet { applyVolumes() }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bardo-preview-\(UUID().uuidString)", isDirectory: true)
    private var source: URL?
    private var excerptURL: URL?
    private var compressedURLs: [AudioQualityPreset: URL] = [:]
    private var original: AVAudioPlayer?
    private var compressed: AVAudioPlayer?
    private var preparation: Task<Void, Never>?
    private var progressTimer: Timer?

    /// Prepares `source` at `preset`. Playback carries on from the same moment once the
    /// new version is ready.
    func prepare(source: URL, duration sourceDuration: TimeInterval, preset: AudioQualityPreset) {
        preparation?.cancel()
        let resumes = isPlaying
        let resumeAt = position
        pausePlayers()

        if source != self.source {
            self.source = source
            excerptURL = nil
            compressedURLs = [:]
            position = 0
            duration = 0
        }
        state = .preparing

        let directory = workDirectory
        let start = AudioExcerpt.start(forDuration: sourceDuration)
        let cachedExcerpt = excerptURL
        let cachedCompressed = compressedURLs[preset]

        preparation = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let excerpt: URL
                if let cachedExcerpt {
                    excerpt = cachedExcerpt
                } else {
                    excerpt = directory.appendingPathComponent("excerpt-\(UUID().uuidString).caf")
                    try await Task.detached(priority: .userInitiated) {
                        _ = try AudioExcerpt.write(from: source, start: start, to: excerpt)
                    }.value
                }
                let compressedURL: URL
                if let cachedCompressed {
                    compressedURL = cachedCompressed
                } else {
                    compressedURL = directory.appendingPathComponent("\(preset.rawValue)-\(UUID().uuidString).m4a")
                    try await AudioFileTranscoder().transcode(
                        from: excerpt,
                        to: compressedURL,
                        encoding: AudioEncoding(preset: preset, format: .aac)
                    )
                }
                try Task.checkCancellation()
                self?.load(excerpt: excerpt, compressed: compressedURL, preset: preset, resumeAt: resumeAt, resumes: resumes)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unavailable
            }
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard state == .ready, let original, let compressed else { return }
        if position >= duration - 0.05 { position = 0 }
        original.currentTime = position
        compressed.currentTime = position
        applyVolumes()
        // Start both on the same tick of the output device, so they stay in step.
        let startTime = original.deviceCurrentTime + 0.05
        original.play(atTime: startTime)
        compressed.play(atTime: startTime)
        isPlaying = true
        startProgressUpdates()
    }

    func pause() {
        pausePlayers()
    }

    /// Stops playback and removes the excerpts.
    func stop() {
        preparation?.cancel()
        pausePlayers()
        original = nil
        compressed = nil
        source = nil
        excerptURL = nil
        compressedURLs = [:]
        state = .idle
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func load(excerpt: URL, compressed compressedURL: URL, preset: AudioQualityPreset, resumeAt: TimeInterval, resumes: Bool) {
        do {
            let original = try AVAudioPlayer(contentsOf: excerpt)
            let compressed = try AVAudioPlayer(contentsOf: compressedURL)
            original.prepareToPlay()
            compressed.prepareToPlay()
            self.original = original
            self.compressed = compressed
            excerptURL = excerpt
            compressedURLs[preset] = compressedURL
            duration = original.duration
            position = min(resumeAt, duration)
            state = .ready
            if resumes { play() }
        } catch {
            state = .unavailable
        }
    }

    private func applyVolumes() {
        original?.volume = version == .original ? 1 : 0
        compressed?.volume = version == .compressed ? 1 : 0
    }

    private func pausePlayers() {
        if let original { position = original.currentTime }
        original?.pause()
        compressed?.pause()
        isPlaying = false
        stopProgressUpdates()
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func syncProgress() {
        guard let original else { return }
        if original.isPlaying {
            position = original.currentTime
        } else {
            // The excerpt ended: back to the start, ready to listen again.
            compressed?.stop()
            original.stop()
            isPlaying = false
            position = 0
            stopProgressUpdates()
        }
    }
}
