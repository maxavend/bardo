import Foundation

/// The name the person gave themselves in Settings, used for their microphone track.
enum LocalSpeakerName {
    static let defaultsKey = "bardo.local-speaker-name"

    static var current: String? {
        UserDefaults.standard.string(forKey: defaultsKey)?.nonEmptyTrimmed
    }
}

extension Transcript {
    /// What a speaker is called on screen and in exports: the name someone typed, or
    /// else what Bardo knows about them.
    func displayName(for speaker: Speaker, localName: String? = LocalSpeakerName.current) -> String {
        speaker.name?.nonEmptyTrimmed ?? defaultName(for: speaker, localName: localName)
    }

    /// What a speaker is called before anyone names them: "You" for the microphone,
    /// "Others" for the Mac's audio before participants are told apart, and a number
    /// counted among the remaining speakers otherwise.
    func defaultName(for speaker: Speaker, localName: String? = LocalSpeakerName.current) -> String {
        switch speaker.role {
        case .localUser:
            return localName ?? String(localized: "You")
        case .others:
            return String(localized: "Others")
        case nil:
            let numbered = speakers.filter { $0.role == nil }
            let index = numbered.firstIndex { $0.id == speaker.id } ?? 0
            return String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
        }
    }

    func speaker(withID id: Speaker.ID?) -> Speaker? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
