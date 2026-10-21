import Foundation

/// The ways Bardo can turn speech into text, named by what they mean for the person
/// rather than by model: one built into macOS, a balanced one, and the most accurate.
/// Speaker identification is the same whichever is used.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    /// Apple's speech recognition, part of macOS 26 and later.
    case apple
    /// Whisper large-v3 Turbo.
    case balanced
    /// Whisper large-v3 in full.
    case precise

    /// What a Mac with no choice saved uses: what Bardo always installed before it
    /// offered a choice, so nothing changes for anyone who set it up then.
    static let `default` = TranscriptionEngine.balanced
    /// What the welcome suggests: Apple's, which needs no download, where macOS has it.
    static var recommended: TranscriptionEngine {
        TranscriptionEngine.apple.isSupported ? .apple : .balanced
    }
    static let defaultsKey = "bardo.transcription.engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Rápido"
        case .balanced: "Equilibrado"
        case .precise: "Preciso"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Incluido en macOS. Transcribe en segundos en el idioma de este Mac, con algo menos de precisión."
        case .balanced: "Muy preciso y rápido, también con nombres y siglas."
        case .precise: "El más exacto con nombres, acentos y voces que se cruzan. Tarda varias veces más."
        }
    }

    /// What choosing it costs, said plainly.
    var downloadSummary: String {
        guard let bytes = approximateBytes else { return "Sin descargas" }
        return "Descarga \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    /// Who makes it, said once, for the curious.
    var maker: String {
        switch self {
        case .apple: "Apple"
        case .balanced: "Whisper Turbo, de OpenAI"
        case .precise: "Whisper Large, de OpenAI"
        }
    }

    /// The local model Bardo downloads and can remove; Apple's lives in macOS.
    var managedModel: ManagedModel? {
        switch self {
        case .apple: nil
        case .balanced: .whisperTurbo
        case .precise: .whisperLarge
        }
    }

    /// About how much it takes on disk.
    var approximateBytes: Int64? {
        switch self {
        case .apple: nil
        case .balanced: 646_000_000
        case .precise: 3_090_000_000
        }
    }

    /// Whether this Mac can use it at all.
    var isSupported: Bool {
        guard self == .apple else { return true }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var selection: TranscriptionSelection {
        switch self {
        case .apple: TranscriptionSelection(backend: .appleSpeech, modelID: rawValue)
        case .balanced: TranscriptionSelection(modelID: TranscriptionModelManager.modelID)
        case .precise: TranscriptionSelection(modelID: TranscriptionModelManager.largeModelID)
        }
    }

    /// The engine chosen in Settings, falling back to the default where it is not supported.
    static func current(in defaults: UserDefaults = .standard) -> TranscriptionEngine {
        let chosen = defaults.string(forKey: defaultsKey).flatMap(TranscriptionEngine.init(rawValue:)) ?? .default
        return chosen.isSupported ? chosen : .default
    }
}
