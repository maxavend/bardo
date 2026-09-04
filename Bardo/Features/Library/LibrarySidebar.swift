import SwiftUI

struct LibrarySidebar: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel
    @Binding var selection: BardoLibrarySection

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(BardoLibrarySection.allCases) { section in
                    Label {
                        HStack(spacing: 8) {
                            Text(section.title)
                            Spacer(minLength: 4)
                            if let count = count(for: section), count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .tag(section)
                }
            }

            if activeProcessingCount > 0 {
                Section("Actividad") {
                    Label {
                        HStack {
                            Text(activityLabel)
                            Spacer()
                            ProgressView()
                                .controlSize(.mini)
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Bardo")
        .navigationSplitViewColumnWidth(
            min: BardoLayout.librarySidebarMinWidth,
            ideal: BardoLayout.librarySidebarIdealWidth,
            max: BardoLayout.librarySidebarMaxWidth
        )
        .enableInjection()
    }

    private var activeProcessingCount: Int {
        Set(
            [
                model.transcriptionRecordingID,
                model.diarizationRecordingID,
                model.isGeneratingMeetingMinutes ? model.selection : nil
            ].compactMap { $0 }
        ).count
    }

    private var activityLabel: String {
        if activeProcessingCount == 1 { return "1 conversación en proceso" }
        return "\(activeProcessingCount) conversaciones en proceso"
    }

    private func count(for section: BardoLibrarySection) -> Int? {
        switch section {
        case .home, .trash:
            return nil
        case .recordings:
            return model.recordings.filter { !$0.sources.contains(.importedFile) }.count
        case .imported:
            return model.recordings.filter { $0.sources.contains(.importedFile) }.count
        case .minutes:
            return model.recordingIDsWithMinutes.count
        case .favorites:
            return model.recordings.filter { BardoFavoritesStore.shared.contains($0.id) }.count
        }
    }
}
