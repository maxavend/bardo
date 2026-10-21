import Foundation

enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    case whisperKit
    case appleSpeech
}

/// Which engine and model made a transcript. Transcripts from before Bardo offered a
/// choice decode as Whisper large-v3 Turbo, the one engine there was.
struct TranscriptionSelection: Codable, Equatable, Sendable {
    let backend: TranscriptionBackend
    let modelID: String

    init(
        backend: TranscriptionBackend = .whisperKit,
        modelID: String = TranscriptionModelManager.modelID
    ) {
        self.backend = backend
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case backend
        case modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let backend = try container.decodeIfPresent(String.self, forKey: .backend).flatMap(TranscriptionBackend.init(rawValue:))
        let modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        switch backend {
        case .appleSpeech:
            self.backend = .appleSpeech
            self.modelID = modelID ?? TranscriptionEngine.apple.rawValue
        case .whisperKit where modelID == TranscriptionModelManager.largeModelID:
            self.backend = .whisperKit
            self.modelID = TranscriptionModelManager.largeModelID
        default:
            self.backend = .whisperKit
            self.modelID = TranscriptionModelManager.modelID
        }
    }
}
