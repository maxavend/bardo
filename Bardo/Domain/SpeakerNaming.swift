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

extension Transcript {
    /// The transcript with everything `sourceID` said given to `targetID`, for one person
    /// that was told apart as two. You on the microphone always stay you, and a name
    /// someone typed is kept when the other has none.
    func mergingSpeaker(_ sourceID: Speaker.ID, into targetID: Speaker.ID) -> Transcript {
        guard sourceID != targetID,
              let source = speakers.first(where: { $0.id == sourceID }),
              let target = speakers.first(where: { $0.id == targetID }) else { return self }
        let (kept, removed) = source.role == .localUser && target.role != .localUser
            ? (source, target)
            : (target, source)

        var merged = self
        if let index = merged.speakers.firstIndex(where: { $0.id == kept.id }),
           kept.name?.nonEmptyTrimmed == nil {
            merged.speakers[index].name = removed.name?.nonEmptyTrimmed
        }
        for index in merged.segments.indices where merged.segments[index].speakerID == removed.id {
            merged.segments[index].speakerID = kept.id
        }
        merged.speakers.removeAll { $0.id == removed.id }
        return merged
    }

    /// Participants given the same name, which are most likely one person.
    func speakersSharingAName(_ names: [Speaker.ID: String]) -> [[Speaker.ID]] {
        var groups: [String: [Speaker.ID]] = [:]
        var order: [String] = []
        for speaker in speakers {
            guard let name = (names[speaker.id] ?? speaker.name)?.nonEmptyTrimmed else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(speaker.id)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }
}
