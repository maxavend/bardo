import Foundation


enum BardoLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case spanish = "es"

    static let storageKey = "Bardo.AppLanguage"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    static var preferredDefault: BardoLanguage {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else { return .english }
        return preferred.hasPrefix("es") ? .spanish : .english
    }

    static func resolve(_ rawValue: String) -> BardoLanguage {
        BardoLanguage(rawValue: rawValue) ?? preferredDefault
    }
}

enum BardoL10n {
    /// Resolves dynamic strings from the same Localizable.strings resources SwiftUI uses for
    /// literal Text/Button labels. The explicit locale is what makes the in-app language
    /// setting update immediately without changing macOS language preferences.
    static func string(_ key: String, locale: Locale) -> String {
        let languageCode = locale.language.languageCode?.identifier ?? BardoLanguage.english.rawValue
        let supported = BardoLanguage(rawValue: languageCode) ?? .english
        guard let path = Bundle.main.path(forResource: supported.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }
}
