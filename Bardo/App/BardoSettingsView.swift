import SwiftUI

struct BardoSettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general
        case transcription
        case context

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .general: "gearshape"
            case .transcription: "waveform.badge.mic"
            case .context: "text.badge.plus"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .transcription: "Transcription"
            case .context: "Context"
            }
        }
    }

    @AppStorage(BardoLanguage.storageKey) private var languageRaw = BardoLanguage.preferredDefault.rawValue
    @AppStorage(TranscriptionLanguagePreference.storageKey) private var transcriptionLanguageRaw = TranscriptionLanguagePreference.preferredDefault.rawValue
    @AppStorage("Bardo.Settings.SelectedPane") private var selectedPaneRaw = Pane.transcription.rawValue

    @State private var contextCategories: [TranscriptionContextCategory]
    @State private var selectedContextID: TranscriptionContextCategory.ID?
    @State private var isRemoveAllConfirmationPresented = false

    init() {
        let categories = TranscriptionContextPreferences.load()
        _contextCategories = State(initialValue: categories)
        _selectedContextID = State(initialValue: categories.first?.id)
    }

    private var language: BardoLanguage {
        BardoLanguage.resolve(languageRaw)
    }

    private var activeCategoryCount: Int {
        contextCategories.filter { $0.isEnabled && !$0.terms.isEmpty }.count
    }

    private var activeTermCount: Int {
        TranscriptionContextPreferences.activeTerms(in: contextCategories).count
    }

    private var paneSelection: Binding<Pane?> {
        Binding(
            get: { Pane(rawValue: selectedPaneRaw) ?? .transcription },
            set: { pane in
                if let pane {
                    selectedPaneRaw = pane.rawValue
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: paneSelection) { pane in
                Label {
                    Text(pane.titleKey, tableName: "TranscriptUI")
                } icon: {
                    Image(systemName: pane.iconName)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 182, max: 210)
        } detail: {
            switch Pane(rawValue: selectedPaneRaw) ?? .transcription {
            case .general:
                generalPane
            case .transcription:
                transcriptionPane
            case .context:
                contextPane
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 500, idealHeight: 620)
        .environment(\.locale, language.locale)
        .onChange(of: contextCategories) { _, categories in
            TranscriptionContextPreferences.save(categories)
            if let selectedContextID,
               !categories.contains(where: { $0.id == selectedContextID }) {
                self.selectedContextID = categories.first?.id
            }
        }
        .alert(
            Text("Remove All Context?", tableName: "TranscriptUI"),
            isPresented: $isRemoveAllConfirmationPresented
        ) {
            Button(role: .destructive) {
                contextCategories.removeAll()
                selectedContextID = nil
            } label: {
                Text("Remove All", tableName: "TranscriptUI")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", tableName: "TranscriptUI")
            }
        } message: {
            Text(
                "All context categories and their terms will be removed. This cannot be undone.",
                tableName: "TranscriptUI"
            )
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                Picker(selection: $languageRaw) {
                    ForEach(BardoLanguage.allCases) { language in
                        Text(language.displayName)
                            .tag(language.rawValue)
                    }
                } label: {
                    Text("App Language", tableName: "TranscriptUI")
                }
                .pickerStyle(.menu)

                Text(
                    "Changes the interface immediately and is remembered for the next launch.",
                    tableName: "TranscriptUI"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var transcriptionPane: some View {
        Form {
            Section {
                Picker(selection: $transcriptionLanguageRaw) {
                    Text("Automatic", tableName: "TranscriptUI")
                        .tag(TranscriptionLanguagePreference.automatic.rawValue)
                    Text("Español")
                        .tag(TranscriptionLanguagePreference.spanish.rawValue)
                    Text("English")
                        .tag(TranscriptionLanguagePreference.english.rawValue)
                } label: {
                    Text("Primary Spoken Language", tableName: "TranscriptUI")
                }
                .pickerStyle(.radioGroup)

                Text(
                    "Choose the main language you speak. Occasional words, names, and product terms from another language are still transcribed as spoken.",
                    tableName: "TranscriptUI"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            TranscriptionQualitySettingsSection()

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcription only", tableName: "TranscriptUI")
                            .font(.body.weight(.medium))
                        Text(
                            "Bardo always transcribes. It never translates your recording into another language.",
                            tableName: "TranscriptUI"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    selectedPaneRaw = Pane.context.rawValue
                } label: {
                    HStack(spacing: 10) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Transcription Context", tableName: "TranscriptUI")
                                    .foregroundStyle(.primary)
                                Text(
                                    "Give Whisper likely names, product terms, technical vocabulary, and recurring phrases.",
                                    tableName: "TranscriptUI"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "text.badge.plus")
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(activeTermCount)") + Text(" terms", tableName: "TranscriptUI")
                            Text("\(activeCategoryCount)") + Text(" active categories", tableName: "TranscriptUI")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(
                "Language, quality, and context changes are used the next time you transcribe or transcribe again.",
                tableName: "TranscriptUI"
            )
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var contextPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Context", tableName: "TranscriptUI")
                        .font(.headline)
                    Spacer()
                    Button {
                        addContextCategory()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("New Category", tableName: "TranscriptUI"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                if contextCategories.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Context Yet", tableName: "TranscriptUI")
                        } icon: {
                            Image(systemName: "text.badge.plus")
                        }
                    } description: {
                        Text(
                            "Create a category, then paste a whole vocabulary list at once. Commas, semicolons, and line breaks all work.",
                            tableName: "TranscriptUI"
                        )
                    } actions: {
                        Button {
                            addContextCategory()
                        } label: {
                            Text("Create Category", tableName: "TranscriptUI")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedContextID) {
                        ForEach(contextCategories) { category in
                            ContextCategoryRow(category: category)
                                .tag(category.id)
                        }
                    }
                    .listStyle(.sidebar)
                }

                if !contextCategories.isEmpty {
                    Divider()
                    HStack {
                        Text("\(activeTermCount)") + Text(" active terms", tableName: "TranscriptUI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            isRemoveAllConfirmationPresented = true
                        } label: {
                            Text("Remove All…", tableName: "TranscriptUI")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)

            Divider()

            if let selectedContextID,
               let category = categoryBinding(for: selectedContextID) {
                contextCategoryEditor(category)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Select a Context Category", tableName: "TranscriptUI")
                    } icon: {
                        Image(systemName: "text.badge.plus")
                    }
                } description: {
                    Text("Choose a category to edit its name and terms.", tableName: "TranscriptUI")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func contextCategoryEditor(
        _ category: Binding<TranscriptionContextCategory>
    ) -> some View {
        let termCount = category.wrappedValue.terms.count

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField(
                    "",
                    text: category.name,
                    prompt: Text("Category Name", tableName: "TranscriptUI")
                )
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))

                Spacer(minLength: 12)

                Toggle(isOn: category.isEnabled) {
                    Text("Enabled", tableName: "TranscriptUI")
                }
                .toggleStyle(.switch)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Terms", tableName: "TranscriptUI")
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("\(termCount)") + Text(" terms detected", tableName: "TranscriptUI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: category.termsText)
                    .font(.body)
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }

                Text(
                    "Separate terms with commas, semicolons, or line breaks. Bardo normalizes spacing and duplicates automatically.",
                    tableName: "TranscriptUI"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label {
                Text(
                    "Context nudges recognition toward likely spellings; it does not force replacements and it never translates the recording.",
                    tableName: "TranscriptUI"
                )
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack {
                Button(role: .destructive) {
                    removeContextCategory(id: category.wrappedValue.id)
                } label: {
                    Label {
                        Text("Delete Category", tableName: "TranscriptUI")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }

                Spacer()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func categoryBinding(
        for id: TranscriptionContextCategory.ID
    ) -> Binding<TranscriptionContextCategory>? {
        guard let index = contextCategories.firstIndex(where: { $0.id == id }) else { return nil }
        return $contextCategories[index]
    }

    private func addContextCategory() {
        let category = TranscriptionContextCategory()
        contextCategories.append(category)
        selectedContextID = category.id
    }

    private func removeContextCategory(id: TranscriptionContextCategory.ID) {
        contextCategories.removeAll { $0.id == id }
        selectedContextID = contextCategories.first?.id
    }
}

private struct ContextCategoryRow: View {
    let category: TranscriptionContextCategory

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .lineLimit(1)
                Text("\(category.terms.count)") + Text(" terms", tableName: "TranscriptUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if !category.isEnabled {
                Image(systemName: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Disabled", tableName: "TranscriptUI"))
            }
        }
        .opacity(category.isEnabled ? 1 : 0.72)
    }

    private var displayName: String {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? LibraryFormatting.localized("Untitled Category") : name
    }
}
