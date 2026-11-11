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
        case unavailable(String)
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
    private var source: AudioCompressionInput?
    private var excerptURL: URL?
    private var compressedURLs: [AudioCompressionEncoding: URL] = [:]
    private var original: AVAudioPlayer?
    private var compressed: AVAudioPlayer?
    private var preparation: Task<Void, Never>?
    private var progressTimer: Timer?

    /// Prepares `source` using `encoding`. Playback carries on from the same moment once the
    /// new version is ready.
    func prepare(source: AudioCompressionInput, encoding: AudioCompressionEncoding) {
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
        let cachedExcerpt = excerptURL
        let cachedCompressed = compressedURLs[encoding]

        preparation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let excerpt: URL
                if let cachedExcerpt {
                    excerpt = cachedExcerpt
                } else {
                    excerpt = directory.appendingPathComponent("excerpt-\(UUID().uuidString).caf")
                    try await AudioCompressionTranscoder.writeExcerpt(from: source, to: excerpt)
                }
                let compressedURL: URL
                if let cachedCompressed {
                    compressedURL = cachedCompressed
                } else {
                    let encoded = directory.appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(encoding.format.fileExtension)
                    try await AudioCompressionTranscoder.encode(
                        from: excerpt,
                        to: encoded,
                        using: encoding
                    )
                    try Task.checkCancellation()
                    if encoding.format == .opus {
                        let decoded = encoded.deletingPathExtension().appendingPathExtension("wav")
                        try await AudioCompressionTranscoder.decodeOpusPreview(from: encoded, to: decoded)
                        compressedURL = decoded
                    } else {
                        compressedURL = encoded
                    }
                }
                try Task.checkCancellation()
                self?.load(excerpt: excerpt, compressed: compressedURL, encoding: encoding, resumeAt: resumeAt, resumes: resumes)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unavailable(error.localizedDescription)
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

    func showUnavailable() {
        stop()
        state = .unavailable("No se pudo preparar la vista previa del audio.")
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

    private func load(excerpt: URL, compressed compressedURL: URL, encoding: AudioCompressionEncoding, resumeAt: TimeInterval, resumes: Bool) {
        do {
            let original = try AVAudioPlayer(contentsOf: excerpt)
            let compressed = try AVAudioPlayer(contentsOf: compressedURL)
            original.prepareToPlay()
            compressed.prepareToPlay()
            self.original = original
            self.compressed = compressed
            excerptURL = excerpt
            compressedURLs[encoding] = compressedURL
            duration = original.duration
            position = min(resumeAt, duration)
            state = .ready
            if resumes { play() }
        } catch {
            state = .unavailable(error.localizedDescription)
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
