import SwiftUI

struct BardoSettingsView: View {
    @AppStorage(BardoLanguage.storageKey) private var languageRaw = BardoLanguage.preferredDefault.rawValue
    @AppStorage(TranscriptionLanguagePreference.storageKey) private var transcriptionLanguageRaw = TranscriptionLanguagePreference.preferredDefault.rawValue

    private var language: BardoLanguage {
        BardoLanguage.resolve(languageRaw)
    }

    var body: some View {
        Form {
            Section("Language") {
                Picker("App Language", selection: $languageRaw) {
                    ForEach(BardoLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Transcription") {
                Picker("Primary Spoken Language", selection: $transcriptionLanguageRaw) {
                    Text("Automatic")
                        .tag(TranscriptionLanguagePreference.automatic.rawValue)
                    Text("Español")
                        .tag(TranscriptionLanguagePreference.spanish.rawValue)
                    Text("English")
                        .tag(TranscriptionLanguagePreference.english.rawValue)
                }
                .pickerStyle(.radioGroup)

                Text("Choose the main language you speak. Occasional words, names, and product terms from another language are still transcribed as spoken.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Label("Bardo always transcribes. It never translates your recording into another language.", systemImage: "captions.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("The app language change applies immediately. Transcription language is used the next time you transcribe or transcribe again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 500, height: 430)
        .environment(\.locale, language.locale)
    }
}
