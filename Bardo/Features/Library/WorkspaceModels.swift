import Foundation
import SwiftUI

enum BardoLibrarySection: String, CaseIterable, Identifiable, Hashable {
    case home
    case recordings
    case imported
    case minutes
    case favorites
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Inicio"
        case .recordings: "Grabaciones"
        case .imported: "Importados"
        case .minutes: "Minutas"
        case .favorites: "Favoritos"
        case .trash: "Papelera"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recordings: "waveform"
        case .imported: "square.and.arrow.down"
        case .minutes: "list.bullet.clipboard"
        case .favorites: "star"
        case .trash: "trash"
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
    let participantNames: [String]
    let transcriptText: String
    let minutesText: String

    var hasMinutes: Bool {
        !minutesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func match(query: String) -> LibrarySearchMatch? {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !terms.isEmpty else { return nil }

        let haystack = [
            title,
            participantNames.joined(separator: " "),
            transcriptText,
            minutesText
        ].joined(separator: "\n")

        guard terms.allSatisfy({ haystack.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }

        if let participant = participantNames.first(where: { name in
            terms.contains(where: { name.localizedCaseInsensitiveContains($0) })
        }) {
            return LibrarySearchMatch(
                recordingID: id,
                title: title,
                context: "Participante: \(participant)",
                symbol: "person"
            )
        }

        if let snippet = Self.snippet(in: transcriptText, matching: terms) {
            return LibrarySearchMatch(
                recordingID: id,
                title: title,
                context: snippet,
                symbol: "text.bubble"
            )
        }

        if let snippet = Self.snippet(in: minutesText, matching: terms) {
            return LibrarySearchMatch(
                recordingID: id,
                title: title,
                context: snippet,
                symbol: "list.bullet.clipboard"
            )
        }

        return LibrarySearchMatch(
            recordingID: id,
            title: title,
            context: createdAt.formatted(.dateTime.day().month(.abbreviated).year()),
            symbol: "waveform"
        )
    }

    private static func snippet(in text: String, matching terms: [String]) -> String? {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let term = terms.first(where: { clean.localizedCaseInsensitiveContains($0) }),
              let range = clean.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return nil
        }

        let lowerDistance = min(70, clean.distance(from: clean.startIndex, to: range.lowerBound))
        let upperDistance = min(110, clean.distance(from: range.upperBound, to: clean.endIndex))
        let lower = clean.index(range.lowerBound, offsetBy: -lowerDistance)
        let upper = clean.index(range.upperBound, offsetBy: upperDistance)
        let prefix = lower == clean.startIndex ? "" : "…"
        let suffix = upper == clean.endIndex ? "" : "…"
        return prefix + clean[lower..<upper] + suffix
    }
}

struct LibrarySearchMatch: Identifiable, Equatable, Sendable {
    var id: Recording.ID { recordingID }
    let recordingID: Recording.ID
    let title: String
    let context: String
    let symbol: String
}
