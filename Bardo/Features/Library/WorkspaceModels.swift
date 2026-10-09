import Foundation
import SwiftUI

/// The Library filters shown in the sidebar. Each one is a view of the same
/// conversations, so a conversation can appear in several of them.
enum BardoLibrarySection: String, CaseIterable, Identifiable, Hashable {
    case all
    case recorded
    case imported
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todas"
        case .recorded: "Grabadas"
        case .imported: "Importadas"
        case .favorites: "Favoritas"
        }
    }

    var symbol: String {
        switch self {
        case .all: "waveform"
        case .recorded: "mic"
        case .imported: "square.and.arrow.down"
        case .favorites: "star"
        }
    }

    @MainActor
    func contains(_ recording: Recording, favorites: BardoFavoritesStore) -> Bool {
        switch self {
        case .all: true
        case .recorded: !recording.sources.contains(.importedFile)
        case .imported: recording.sources.contains(.importedFile)
        case .favorites: favorites.contains(recording.id)
        }
    }
}

enum BardoLibrarySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Más recientes primero"
        case .oldest: "Más antiguas primero"
        case .name: "Nombre"
        case .duration: "Duración"
        }
    }

    func sorted(_ recordings: [Recording]) -> [Recording] {
        switch self {
        case .newest:
            recordings.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            recordings.sorted { $0.createdAt < $1.createdAt }
        case .name:
            recordings.sorted {
                LibraryFormatting.recordingTitle($0)
                    .localizedStandardCompare(LibraryFormatting.recordingTitle($1)) == .orderedAscending
            }
        case .duration:
            recordings.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }
}

@MainActor
final class BardoFavoritesStore: ObservableObject {
    static let shared = BardoFavoritesStore()

    @Published private(set) var ids: Set<Recording.ID>

    private let defaults: UserDefaults
    private let key = "bardo.favorite-recording-ids"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(
            (defaults.stringArray(forKey: key) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
    }

    func contains(_ id: Recording.ID) -> Bool {
        ids.contains(id)
    }

    func toggle(_ id: Recording.ID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        persist()
    }

    func remove(_ id: Recording.ID) {
        guard ids.remove(id) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

struct LibrarySearchDocument: Identifiable, Equatable, Sendable {
    let id: Recording.ID
    let title: String
    let createdAt: Date
    let duration: TimeInterval?
    let source: String
    /// Every speaker, with "Speaker N" for the ones nobody named yet.
    let participantNames: [String]
    /// Only the names a person typed.
    var namedParticipants: [String] = []
    let transcriptText: String

    func match(query: String) -> LibrarySearchMatch? {
        let terms = LibraryFormatting.searchTerms(query)
        guard !terms.isEmpty else { return nil }

        let haystack = [
            title,
            participantNames.joined(separator: " "),
            transcriptText
        ].joined(separator: "\n")

        // People search without accents: "diseno" finds "diseño".
        guard terms.allSatisfy({ Self.contains($0, in: haystack) }) else {
            return nil
        }

        if let participant = participantNames.first(where: { name in
            terms.contains(where: { Self.contains($0, in: name) })
        }) {
            return LibrarySearchMatch(recordingID: id, kind: .participant, context: "Participante: \(participant)")
        }

        if let snippet = Self.snippet(in: transcriptText, matching: terms) {
            return LibrarySearchMatch(recordingID: id, kind: .transcript, context: snippet)
        }

        return LibrarySearchMatch(recordingID: id, kind: .title, context: title)
    }

    private static func contains(_ term: String, in text: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func snippet(in text: String, matching terms: [String]) -> String? {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let term = terms.first(where: { contains($0, in: clean) }),
              let range = clean.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return nil
        }

        let lowerDistance = min(70, clean.distance(from: clean.startIndex, to: range.lowerBound))
        let upperDistance = min(110, clean.distance(from: range.upperBound, to: clean.endIndex))
        var lower = clean.index(range.lowerBound, offsetBy: -lowerDistance)
        var upper = clean.index(range.upperBound, offsetBy: upperDistance)
        // Start and end on whole words, never "…nces mañana".
        if lower > clean.startIndex, let space = clean[lower..<range.lowerBound].firstIndex(of: " ") {
            lower = clean.index(after: space)
        }
        if upper < clean.endIndex, let space = clean[range.upperBound..<upper].lastIndex(of: " ") {
            upper = space
        }
        let prefix = lower == clean.startIndex ? "" : "…"
        let suffix = upper == clean.endIndex ? "" : "…"
        return prefix + clean[lower..<upper] + suffix
    }
}

struct LibrarySearchMatch: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case title
        case participant
        case transcript
    }

    var id: Recording.ID { recordingID }
    let recordingID: Recording.ID
    let kind: Kind
    /// A short excerpt that shows why the conversation matched.
    let context: String
}
