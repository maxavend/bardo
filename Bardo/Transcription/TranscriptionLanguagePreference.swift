import Foundation

enum TranscriptionLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case spanish = "es"
    case english = "en"

    static let storageKey = "Bardo.TranscriptionLanguage"

    var id: String { rawValue }

    var whisperLanguageCode: String? {
        switch self {
        case .automatic:
            nil
        case .spanish, .english:
            rawValue
        }
    }

    static var preferredDefault: TranscriptionLanguagePreference {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return .english
        }
        return preferred.hasPrefix("es") ? .spanish : .english
    }

    static func resolve(_ rawValue: String?) -> TranscriptionLanguagePreference {
        guard let rawValue,
              let preference = TranscriptionLanguagePreference(rawValue: rawValue) else {
            return preferredDefault
        }
        return preference
    }

    static var current: TranscriptionLanguagePreference {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }
}

struct TranscriptionLanguagePolicy: Equatable, Sendable {
    let languageCode: String?
    let detectsLanguage: Bool

    static func make(
        preference: TranscriptionLanguagePreference,
        lockedLanguageCode: String?
    ) -> TranscriptionLanguagePolicy {
        if let preferredLanguageCode = preference.whisperLanguageCode {
            return TranscriptionLanguagePolicy(
                languageCode: preferredLanguageCode,
                detectsLanguage: false
            )
        }

        if let lockedLanguageCode,
           !lockedLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TranscriptionLanguagePolicy(
                languageCode: lockedLanguageCode,
                detectsLanguage: false
            )
        }

        return TranscriptionLanguagePolicy(languageCode: nil, detectsLanguage: true)
    }
}
