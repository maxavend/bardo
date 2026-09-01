import Foundation

enum TranscriptionQuality: String, CaseIterable, Identifiable, Sendable {
    case instant
    case balanced
    case maximum

    static let storageKey = "Bardo.TranscriptionQuality"

    var id: String { rawValue }

    static var preferredDefault: TranscriptionQuality { .balanced }

    static func resolve(_ rawValue: String?) -> TranscriptionQuality {
        guard let rawValue,
              let quality = TranscriptionQuality(rawValue: rawValue) else {
            return preferredDefault
        }
        return quality
    }

    static var current: TranscriptionQuality {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    var modelID: String {
        switch self {
        case .instant:
            ParakeetTranscriptionService.modelID
        case .balanced:
            TranscriptionModelManager.fastModelID
        case .maximum:
            TranscriptionModelManager.maximumAccuracyModelID
        }
    }

    var modelDisplayName: String {
        switch self {
        case .instant:
            "Parakeet TDT 0.6B v3"
        case .balanced:
            "Whisper large-v3 Turbo"
        case .maximum:
            "Whisper large-v3"
        }
    }

    var engineDisplayName: String {
        switch self {
        case .instant:
            "Parakeet"
        case .balanced, .maximum:
            "Whisper"
        }
    }

    var approximateDownloadBytes: Int64 {
        switch self {
        case .instant:
            500_000_000
        case .balanced:
            632_000_000
        case .maximum:
            626_000_000
        }
    }
}

struct TranscriptionModelState: Equatable, Sendable {
    let quality: TranscriptionQuality
    let isInstalled: Bool
    let sizeBytes: Int64?
}
