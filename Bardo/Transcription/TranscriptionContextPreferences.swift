import Foundation

struct TranscriptionContextCategory: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var termsText: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        termsText: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.termsText = termsText
        self.isEnabled = isEnabled
    }

    var terms: [String] {
        TranscriptionContextParser.terms(from: termsText)
    }
}

enum TranscriptionContextParser {
    private static let separators = CharacterSet(charactersIn: ",;\n")
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func terms(from text: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for candidate in text.components(separatedBy: separators) {
            let normalized = normalize(candidate)
            guard !normalized.isEmpty else { continue }

            let comparisonKey = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: comparisonLocale
            )
            guard seen.insert(comparisonKey).inserted else { continue }
            result.append(normalized)
        }

        return result
    }

    static func normalizedText(from text: String) -> String {
        terms(from: text).joined(separator: ", ")
    }

    private static func normalize(_ value: String) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return stripWrappingQuotes(from: collapsed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(from value: String) -> String {
        guard let first = value.first, let last = value.last, value.count >= 2 else {
            return value
        }

        let isWrapped = (first == "\"" && last == "\"")
            || (first == "'" && last == "'")
            || (first == "“" && last == "”")
            || (first == "‘" && last == "’")
        guard isWrapped else { return value }

        return String(value.dropFirst().dropLast())
    }
}

enum TranscriptionContextPreferences {
    static let storageKey = "Bardo.TranscriptionContextCategories.v1"

    static func load(userDefaults: UserDefaults = .standard) -> [TranscriptionContextCategory] {
        guard let data = userDefaults.data(forKey: storageKey),
              let categories = try? JSONDecoder().decode([TranscriptionContextCategory].self, from: data) else {
            return []
        }
        return categories
    }

    static func save(
        _ categories: [TranscriptionContextCategory],
        userDefaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    static var currentCategories: [TranscriptionContextCategory] {
        load()
    }

    static var currentPromptText: String? {
        promptText(from: currentCategories)
    }

    static func activeTerms(in categories: [TranscriptionContextCategory]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let locale = Locale(identifier: "en_US_POSIX")

        for category in categories where category.isEnabled {
            for term in category.terms {
                let comparisonKey = term.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: locale
                )
                guard seen.insert(comparisonKey).inserted else { continue }
                result.append(term)
            }
        }

        return result
    }

    static func promptText(from categories: [TranscriptionContextCategory]) -> String? {
        let terms = activeTerms(in: categories)
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }
}
