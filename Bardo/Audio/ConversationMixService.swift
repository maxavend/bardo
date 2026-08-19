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

        // Two full-scale sources can clip when summed. A fixed -6 dB-ish safety gain
        // (0.5 linear) is deterministic, preserves relative dynamics, and avoids inventing
        // loudness normalization before Bardo actually needs it.
        let systemParameters = AVMutableAudioMixInputParameters(track: systemTrack)
        systemParameters.setVolume(0.5, at: .zero)
        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
        microphoneParameters.setVolume(0.5, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [systemParameters, microphoneParameters]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversationMixError.couldNotCreateExporter
        }

        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.audioMix = audioMix

        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exporter.status == .completed else {
            throw ConversationMixError.exportFailed(
                exporter.error?.localizedDescription ?? "AVAssetExportSession did not complete."
            )
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
            return "One of the original sources has no readable audio track."
        case .couldNotCreateComposition:
            return "Bardo could not create tracks for the conversation mix."
        case .couldNotCreateExporter:
            return "Bardo could not create an audio-only M4A exporter."
        case .exportFailed(let message):
            return "Bardo could not generate the conversation mix: \(message)"
        }
    }
}
