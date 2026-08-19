import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Library")
                .toolbar {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                }
        } detail: {
            detail
        }
        .task {
            await model.reload()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.isLoading && model.recordings.isEmpty {
            ProgressView("Loading Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.recordings.isEmpty {
            ContentUnavailableView {
                Label("Library Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty {
            ContentUnavailableView(
                "No Recordings",
                systemImage: "waveform",
                description: Text("Recordings saved by Bardo will appear here.")
            )
        } else {
            List(selection: $model.selection) {
                if !model.issues.isEmpty {
                    Section {
                        Label(
                            "\(model.issues.count) stored item\(model.issues.count == 1 ? "" : "s") need recovery",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                        .help("Bardo preserved these entries and loaded the healthy recordings.")
                    }
                }

                Section("Recordings") {
                    ForEach(model.recordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = model.selectedRecording {
            RecordingDetail(recording: recording)
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "sidebar.left",
                description: Text("Choose a recording from the Library to inspect its metadata.")
            )
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(1)

            Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(durationText(recording.duration))
                Text("•")
                Text(sourceText(recording.sources))
                Text("•")
                Text(stateText(recording.processingState))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct RecordingDetail: View {
    let recording: Recording

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Title", value: recording.title)
                LabeledContent("Created") {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Duration", value: durationText(recording.duration))
                LabeledContent("Source", value: sourceText(recording.sources))
                LabeledContent("State", value: stateText(recording.processingState))
                LabeledContent("ID", value: recording.id.uuidString)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(recording.title)
    }
}

private func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "Unknown" }
    let seconds = max(0, Int(duration.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func sourceText(_ sources: Set<AudioSource>) -> String {
    guard !sources.isEmpty else { return "Unknown source" }
    return sources
        .sorted { $0.rawValue < $1.rawValue }
        .map { source in
            switch source {
            case .microphone: "Microphone"
            case .systemAudio: "System audio"
            case .importedFile: "Imported file"
            }
        }
        .joined(separator: " + ")
}

private func stateText(_ state: ProcessingState) -> String {
    switch state {
    case .pending: "Pending"
    case .processing: "Processing"
    case .completed: "Completed"
    case .failed: "Failed"
    }
}
