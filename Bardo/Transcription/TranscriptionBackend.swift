import Foundation

enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisperKit

    static let parakeetModelID = "parakeet-tdt-0.6b-v3"
}

enum TranscriptionPreset: String, Codable, CaseIterable, Sendable {
    case instant
    case balanced
    case maximumAccuracy
}

struct TranscriptionSelection: Codable, Equatable, Sendable {
    let preset: TranscriptionPreset
    let backend: TranscriptionBackend
    let modelID: String
}

struct TranscriptionOption: Identifiable, Equatable, Sendable {
    let preset: TranscriptionPreset
    let title: String
    let detail: String
    let selection: TranscriptionSelection

    var id: TranscriptionPreset { preset }
    var label: String { "\(title) (\(detail))" }

    static let catalog: [TranscriptionOption] = [
        TranscriptionOption(
            preset: .instant,
            title: "Instant",
            detail: "Parakeet",
            selection: TranscriptionSelection(
                preset: .instant,
                backend: .parakeet,
                modelID: TranscriptionBackend.parakeetModelID
            )
        ),
        TranscriptionOption(
            preset: .balanced,
            title: "Default",
            detail: "Whisper Turbo",
            selection: TranscriptionSelection(
                preset: .balanced,
                backend: .whisperKit,
                modelID: TranscriptionModelManager.balancedModelID
            )
        ),
        TranscriptionOption(
            preset: .maximumAccuracy,
            title: "Más precisión",
            detail: "Whisper Large",
            selection: TranscriptionSelection(
                preset: .maximumAccuracy,
                backend: .whisperKit,
                modelID: TranscriptionModelManager.maximumAccuracyModelID
            )
        )
    ]

    static func option(for preset: TranscriptionPreset) -> TranscriptionOption {
        catalog.first { $0.preset == preset } ?? catalog[1]
    }
}

struct TranscriptionPreferenceStore {
    private static let selectedPresetKey = "Bardo.SelectedTranscriptionPreset"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedPreset() -> TranscriptionPreset {
        guard let rawValue = defaults.string(forKey: Self.selectedPresetKey),
              let preset = TranscriptionPreset(rawValue: rawValue)
        else {
            return .balanced
        }
        return preset
    }

    func setSelectedPreset(_ preset: TranscriptionPreset) {
        defaults.set(preset.rawValue, forKey: Self.selectedPresetKey)
    }
}
