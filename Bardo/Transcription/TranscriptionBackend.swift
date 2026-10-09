import Foundation

enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    case whisperKit
}

/// Metadata kept with a transcript. The decoder accepts the old shape so
/// existing transcripts remain readable, while new transcripts use one engine.
struct TranscriptionSelection: Codable, Equatable, Sendable {
    let backend: TranscriptionBackend
    let modelID: String

    init(
        backend: TranscriptionBackend = .whisperKit,
        modelID: String = TranscriptionModelManager.modelID
    ) {
        _ = backend
        _ = modelID
        self.backend = .whisperKit
        self.modelID = TranscriptionModelManager.modelID
    }

    private enum CodingKeys: String, CodingKey {
        case backend
        case modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(String.self, forKey: .backend)
        _ = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.backend = .whisperKit
        self.modelID = TranscriptionModelManager.modelID
    }
}
