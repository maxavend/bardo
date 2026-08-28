import SwiftUI

struct BardoSettingsView: View {
    @AppStorage(BardoLanguage.storageKey) private var languageRaw = BardoLanguage.preferredDefault.rawValue

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

            Section {
                Text("The language change applies immediately and is remembered for the next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 460, height: 260)
        .environment(\.locale, language.locale)
    }
}
