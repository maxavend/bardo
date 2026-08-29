import SwiftUI

struct BardoSettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general
        case transcription
        case context

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .general:
                "gearshape"
            case .transcription:
                "waveform.badge.mic"
            case .context:
                "text.badge.plus"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .general:
                "General"
            case .transcription:
                "Transcription"
            case .context:
                "Context"
            }
        }
    }

    @AppStorage(BardoLanguage.storageKey) private var languageRaw = BardoLanguage.preferredDefault.rawValue
    @AppStorage(TranscriptionLanguagePreference.storageKey) private var transcriptionLanguageRaw = TranscriptionLanguagePreference.preferredDefault.rawValue

    @State private var selectedPane: Pane? = .transcription
    @State private var contextCategories: [TranscriptionContextCategory]
    @State private var isRemoveAllConfirmationPresented = false

    init() {
        _contextCategories = State(initialValue: TranscriptionContextPreferences.load())
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

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.titleKey, tableName: "TranscriptUI")
                } icon: {
                    Image(systemName: pane.iconName)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 210)
        } detail: {
            Group {
                switch selectedPane ?? .transcription {
                case .general:
                    generalPane
                case .transcription:
                    transcriptionPane
                case .context:
                    contextPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 780, height: 560)
        .environment(\.locale, language.locale)
        .onChange(of: contextCategories) { _, categories in
            TranscriptionContextPreferences.save(categories)
        }
        .alert(
            Text("Remove All Context?", tableName: "TranscriptUI"),
            isPresented: $isRemoveAllConfirmationPresented
        ) {
            Button(role: .destructive) {
                contextCategories.removeAll()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    title: "General",
                    subtitle: "Choose how Bardo appears and behaves on this Mac.",
                    systemImage: "gearshape"
                )

                settingsCard {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("App Language", tableName: "TranscriptUI")
                                .font(.body.weight(.medium))
                            Text(
                                "Changes the interface immediately and is remembered for the next launch.",
                                tableName: "TranscriptUI"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 20)

                        Picker(selection: $languageRaw) {
                            ForEach(BardoLanguage.allCases) { language in
                                Text(language.displayName)
                                    .tag(language.rawValue)
                            }
                        } label: {
                            Text("App Language", tableName: "TranscriptUI")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var transcriptionPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    title: "Transcription",
                    subtitle: "Tune recognition without turning Bardo into a translator.",
                    systemImage: "waveform.badge.mic"
                )

                settingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Primary Spoken Language", tableName: "TranscriptUI")
                                .font(.body.weight(.medium))

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
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            Text(
                                "Choose the main language you speak. Occasional words, names, and product terms from another language are still transcribed as spoken.",
                                tableName: "TranscriptUI"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }

                        Divider()

                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Transcription only", tableName: "TranscriptUI")
                                    .font(.body.weight(.medium))
                                Text(
                                    "Bardo always writes what was said. It never switches Whisper into translation mode.",
                                    tableName: "TranscriptUI"
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "captions.bubble")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                Button {
                    selectedPane = .context
                } label: {
                    settingsCard {
                        HStack(spacing: 14) {
                            Image(systemName: "text.badge.plus")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Transcription Context", tableName: "TranscriptUI")
                                    .font(.body.weight(.medium))
                                Text(
                                    "Give Whisper likely names, product terms, technical vocabulary, and recurring phrases.",
                                    tableName: "TranscriptUI"
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 16)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(activeTermCount)") + Text(" terms", tableName: "TranscriptUI")
                                Text("\(activeCategoryCount)") + Text(" active categories", tableName: "TranscriptUI")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Text(
                    "Language and context changes are used the next time you transcribe or transcribe again.",
                    tableName: "TranscriptUI"
                )
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var contextPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    title: "Context",
                    subtitle: "Organize the words and phrases Bardo should expect to hear.",
                    systemImage: "text.badge.plus"
                )

                HStack(spacing: 10) {
                    Button {
                        addContextCategory()
                    } label: {
                        Label {
                            Text("New Category", tableName: "TranscriptUI")
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if !contextCategories.isEmpty {
                        Text("\(activeTermCount)") + Text(" active terms", tableName: "TranscriptUI")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            isRemoveAllConfirmationPresented = true
                        } label: {
                            Text("Remove All…", tableName: "TranscriptUI")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if contextCategories.isEmpty {
                    settingsCard {
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
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 230)
                    }
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach($contextCategories) { $category in
                            contextCategoryCard(category: $category)
                        }
                    }
                }

                Label {
                    Text(
                        "Context nudges recognition toward likely spellings; it does not force replacements and it never translates the recording.",
                        tableName: "TranscriptUI"
                    )
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func contextCategoryCard(
        category: Binding<TranscriptionContextCategory>
    ) -> some View {
        let termCount = category.wrappedValue.terms.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Toggle(isOn: category.isEnabled) {
                    Text("Enabled", tableName: "TranscriptUI")
                }
                .labelsHidden()
                .toggleStyle(.switch)

                TextField(
                    "",
                    text: category.name,
                    prompt: Text("Category Name", tableName: "TranscriptUI")
                )
                .textFieldStyle(.plain)
                .font(.headline)

                Spacer(minLength: 12)

                Text("\(termCount)") + Text(" terms", tableName: "TranscriptUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    removeContextCategory(id: category.wrappedValue.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(Text("Delete Category", tableName: "TranscriptUI"))
            }

            Divider()

            ZStack(alignment: .topLeading) {
                if category.wrappedValue.termsText.isEmpty {
                    Text(
                        "Figma, FigJam, Auto Layout, SwiftUI, staging, checkout, hacer deploy…",
                        tableName: "TranscriptUI"
                    )
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
                }

                TextEditor(text: category.termsText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92, maxHeight: 126)
                    .padding(2)
            }
            .padding(6)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            }

            HStack {
                Text(
                    "Separate terms with commas, semicolons, or line breaks. Phrases are welcome.",
                    tableName: "TranscriptUI"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button {
                    category.wrappedValue.termsText = TranscriptionContextParser.normalizedText(
                        from: category.wrappedValue.termsText
                    )
                } label: {
                    Label {
                        Text("Clean Up", tableName: "TranscriptUI")
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(termCount == 0)
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
        .opacity(category.wrappedValue.isEnabled ? 1 : 0.72)
    }

    private func pageHeader(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title, tableName: "TranscriptUI")
                    .font(.title2.weight(.semibold))
                Text(subtitle, tableName: "TranscriptUI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
    }

    private func addContextCategory() {
        contextCategories.append(TranscriptionContextCategory())
    }

    private func removeContextCategory(id: TranscriptionContextCategory.ID) {
        contextCategories.removeAll { $0.id == id }
    }
}
