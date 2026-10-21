@preconcurrency import AVFoundation
import Foundation

protocol ConversationMixing: Sendable {
    func makeMix(
        systemURL: URL,
        microphoneURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        outputURL: URL
    ) async throws -> AudioMetadata
}

struct AVFoundationConversationMixer: ConversationMixing {
    private let metadataReader = AudioMetadataReader()
    /// The mix is AAC at the quality chosen in Settings, read when it is made.
    var encoding: @Sendable () -> AudioEncoding = { AudioEncodingPreferences.current() }

    func makeMix(
        systemURL: URL,
        microphoneURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        outputURL: URL
    ) async throws -> AudioMetadata {
        let composition = AVMutableComposition()
        let systemAsset = AVURLAsset(url: systemURL)
        let microphoneAsset = AVURLAsset(url: microphoneURL)

        let systemTracks = try await systemAsset.loadTracks(withMediaType: .audio)
        let microphoneTracks = try await microphoneAsset.loadTracks(withMediaType: .audio)
        guard let systemSource = systemTracks.first, let microphoneSource = microphoneTracks.first else {
            throw ConversationMixError.missingAudioTrack
        }

        let systemDuration = try await systemAsset.load(.duration)
        let microphoneDuration = try await microphoneAsset.load(.duration)
        guard let systemTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let microphoneTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConversationMixError.couldNotCreateComposition
        }

        try systemTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: systemDuration),
            of: systemSource,
            at: CMTime(seconds: max(0, systemOffset), preferredTimescale: 48_000)
        )
        try microphoneTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: microphoneDuration),
            of: microphoneSource,
            at: CMTime(seconds: max(0, microphoneOffset), preferredTimescale: 48_000)
        )

        // Two full-scale sources can clip when summed. A fixed 0.5 linear gain on each
        // source provides deterministic headroom without inventing loudness processing.
        let systemParameters = AVMutableAudioMixInputParameters(track: systemTrack)
        systemParameters.setVolume(0.5, at: .zero)
        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
        microphoneParameters.setVolume(0.5, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [systemParameters, microphoneParameters]

        try? FileManager.default.removeItem(at: outputURL)
        do {
            try await MixRenderer.render(
                composition,
                audioMix: audioMix,
                to: outputURL,
                settings: encoding().mixSettings
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversationMixError.exportFailed(error.localizedDescription)
        }

        return try metadataReader.read(from: outputURL)
    }
}

enum ConversationMixError: Error, LocalizedError, Equatable, Sendable {
    case missingAudioTrack
    case couldNotCreateComposition
    case couldNotCreateExporter
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            return String(localized: "One of the original sources has no readable audio track.")
        case .couldNotCreateComposition:
            return String(localized: "Bardo could not create tracks for the conversation mix.")
        case .couldNotCreateExporter:
            return String(localized: "Bardo could not create an audio-only M4A exporter.")
        case .exportFailed(let message):
            return String(localized: "Bardo could not generate the conversation mix: \(message)")
        }
    }
}

/// Reads the composition through its mix and writes it in one pass, so the mix lands
/// directly at the chosen quality.
private final class MixRenderer: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.maxavend.bardo.mix")

    private init(
        reader: AVAssetReader,
        output: AVAssetReaderAudioMixOutput,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    static func render(
        _ composition: AVComposition,
        audioMix: AVAudioMix,
        to outputURL: URL,
        settings: [String: Any]
    ) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = audioMix
        guard reader.canAdd(output) else { throw ConversationMixError.couldNotCreateExporter }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ConversationMixError.couldNotCreateExporter }
        writer.add(input)

        try await MixRenderer(reader: reader, output: output, writer: writer, input: input).run()
    }

    private func run() async throws {
        guard reader.startReading() else {
            throw reader.error ?? ConversationMixError.couldNotCreateExporter
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? ConversationMixError.couldNotCreateExporter
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ConversationMixError.couldNotCreateExporter
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ConversationMixError.couldNotCreateExporter
        }
    }
}
