import AVFAudio
import Foundation

/// How much detail Bardo keeps of each recording. Every level keeps voices perfectly
/// clear and transcribes the same: transcription listens at 16 kHz, and even the
/// compact level records well above that.
enum AudioQualityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case maximum
    case high
    case balanced
    case compact

    static let `default` = AudioQualityPreset.balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Máxima"
        case .high: "Alta"
        case .balanced: "Equilibrada"
        case .compact: "Compacta"
        }
    }

    var detail: String {
        switch self {
        case .maximum: "Para editar o archivar el audio."
        case .high: "Sonido nítido para volver a escuchar."
        case .balanced: "Voces claras en mucho menos espacio."
        case .compact: "Lo justo para entender y transcribir todo."
        }
    }

    var sampleRate: Double {
        switch self {
        case .maximum, .high: 48_000
        case .balanced: 32_000
        case .compact: 24_000
        }
    }

    /// AAC bit rate for a track; stereo gets more, but not twice, as its channels share
    /// most of what they carry.
    func aacBitRate(channels: Int) -> Int {
        let stereo = channels > 1
        switch self {
        case .maximum: return stereo ? 256_000 : 160_000
        case .high: return stereo ? 160_000 : 96_000
        case .balanced: return stereo ? 96_000 : 64_000
        case .compact: return stereo ? 64_000 : 40_000
        }
    }
}

/// The file format a recording is kept in. MP3 has no encoder on macOS; AAC sounds
/// better at the same size and opens everywhere.
enum AudioStorageFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case aac
    case alac
    case wav

    static let `default` = AudioStorageFormat.aac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aac: "AAC"
        case .alac: "Apple Lossless"
        case .wav: "WAV"
        }
    }

    var detail: String {
        switch self {
        case .aac: "comprimido, se abre en cualquier dispositivo"
        case .alac: "sin pérdida, ocupa más"
        case .wav: "sin comprimir, el más pesado"
        }
    }

    var fileExtension: String {
        switch self {
        case .aac, .alac: "m4a"
        case .wav: "wav"
        }
    }

    var isLossless: Bool { self != .aac }
}

/// A quality and a format together: what files Bardo writes, and how much they weigh.
struct AudioEncoding: Equatable, Sendable {
    var preset: AudioQualityPreset
    var format: AudioStorageFormat

    static let `default` = AudioEncoding(preset: .default, format: .default)

    /// Lossless audio keeps 16 bits per sample: far more than a voice needs.
    static let losslessBitDepth = 16
    /// Apple Lossless keeps roughly this share of the uncompressed size for speech.
    static let losslessShare = 0.55

    var fileExtension: String { format.fileExtension }

    /// Settings for `AVAudioFile` or `AVAssetWriterInput`.
    func outputSettings(channels: Int) -> [String: Any] {
        switch format {
        case .aac:
            return Self.aacSettings(preset: preset, channels: channels)
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: preset.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: Self.losslessBitDepth
            ]
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: preset.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: Self.losslessBitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    /// What a live capture writes while recording. WAV cannot be written in crash-safe
    /// fragments, so it records as Apple Lossless and becomes WAV once it ends.
    func liveOutputSettings(channels: Int) -> [String: Any] {
        format == .wav
            ? AudioEncoding(preset: preset, format: .alac).outputSettings(channels: channels)
            : outputSettings(channels: channels)
    }

    /// The derived conversation mix is for listening and transcribing, so it is always
    /// AAC at this quality.
    var mixSettings: [String: Any] {
        Self.aacSettings(preset: preset, channels: 2)
    }

    static func aacSettings(preset: AudioQualityPreset, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: preset.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: preset.aacBitRate(channels: channels),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    /// About how many bytes a minute of one track takes.
    func bytesPerMinute(channels: Int) -> Double {
        switch format {
        case .aac:
            return Double(preset.aacBitRate(channels: channels)) / 8 * 60
        case .alac, .wav:
            let uncompressed = preset.sampleRate * Double(Self.losslessBitDepth / 8) * Double(channels) * 60
            return format == .alac ? uncompressed * Self.losslessShare : uncompressed
        }
    }

    /// A meeting on this Mac keeps your microphone, the Mac's audio and their mix.
    var meetingBytesPerMinute: Double {
        bytesPerMinute(channels: 1)
            + bytesPerMinute(channels: 2)
            + AudioEncoding(preset: preset, format: .aac).bytesPerMinute(channels: 2)
    }
}

/// The quality and format chosen in Settings, used for every new recording.
enum AudioEncodingPreferences {
    static let presetKey = "bardo.audio.quality"
    static let formatKey = "bardo.audio.format"

    static func current(in defaults: UserDefaults = .standard) -> AudioEncoding {
        AudioEncoding(
            preset: defaults.string(forKey: presetKey).flatMap(AudioQualityPreset.init(rawValue:)) ?? .default,
            format: defaults.string(forKey: formatKey).flatMap(AudioStorageFormat.init(rawValue:)) ?? .default
        )
    }
}
