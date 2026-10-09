import SwiftUI

struct LibrarySidebar: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var favorites: BardoFavoritesStore
    @Binding var selection: BardoLibrarySection

    var body: some View {
        List(selection: $selection) {
            Section("Biblioteca") {
                ForEach(BardoLibrarySection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(count(for: section))
                        .tag(section)
                }
            }

            if activeProcessingCount > 0 {
                Section("Actividad") {
                    Label {
                        Text(activityLabel)
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }
            }

            if !model.issues.isEmpty {
                Section {
                    Label(
                        model.issues.count == 1
                            ? "1 elemento necesita revisión"
                            : "\(model.issues.count) elementos necesitan revisión",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: BardoLayout.librarySidebarMinWidth,
            ideal: BardoLayout.librarySidebarIdealWidth,
            max: BardoLayout.librarySidebarMaxWidth
        )
        .enableInjection()
    }

    private var activeProcessingCount: Int {
        Set([model.transcriptionRecordingID, model.diarizationRecordingID].compactMap { $0 }).count
    }

    private var activityLabel: String {
        if model.transcriptionRecordingID != nil, model.diarizationRecordingID == nil {
            return "Transcribiendo"
        }
        if model.diarizationRecordingID != nil, model.transcriptionRecordingID == nil {
            return "Identificando hablantes"
        }
        return "\(activeProcessingCount) conversaciones en proceso"
    }

    private func count(for section: BardoLibrarySection) -> Int {
        model.recordings.filter { section.contains($0, favorites: favorites) }.count
    }
}
