import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var model: LibraryViewModel
    let onNewRecording: () -> Void
    let onImport: () -> Void

    @State private var searchText = ""
    @State private var recordingToRename: Recording?
    @State private var renameTitle = ""
    @State private var recordingToDelete: Recording?

    var body: some View {
        content
            .navigationTitle("Recordings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .searchable(text: $searchText, prompt: "Search Recordings")
            .alert("Rename Recording", isPresented: renamePresented) {
                TextField("Recording Name", text: $renameTitle)
                Button("Cancel", role: .cancel) {
                    recordingToRename = nil
                }
                Button("Rename") {
                    guard let recording = recordingToRename else { return }
                    Task {
                        _ = await model.renameRecording(id: recording.id, to: renameTitle)
                        recordingToRename = nil
                    }
                }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
            .alert("Delete Recording?", isPresented: deletePresented) {
                Button("Cancel", role: .cancel) {
                    recordingToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    guard let recording = recordingToDelete else { return }
                    Task {
                        _ = await model.deleteRecording(id: recording.id)
                        recordingToDelete = nil
                    }
                }
            } message: {
                Text(deleteMessage)
            }
            .alert(
                "Recording Couldn’t Be Changed",
                isPresented: Binding(
                    get: { model.recordingManagementErrorMessage != nil },
                    set: { if !$0 { model.clearRecordingManagementError() } }
                )
            ) {
                Button("OK") { model.clearRecordingManagementError() }
            } message: {
                Text(model.recordingManagementErrorMessage ?? "Try again.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.recordings.isEmpty {
            ProgressView("Loading Recordings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isImporting && model.recordings.isEmpty {
            ProgressView("Importing Audio…")
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
        } else if model.recordings.isEmpty && !model.issues.isEmpty {
            ContentUnavailableView {
                Label("Library Needs Recovery", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(model.issues.count) stored item\(model.issues.count == 1 ? "" : "s") could not be loaded. Bardo left them untouched.")
            } actions: {
                Button("Reload") {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Start a new recording, import an audio file, or drop audio into this window.")
            } actions: {
                Button("New Recording", action: onNewRecording)
                    .buttonStyle(.borderedProminent)
                Button("Import Audio", action: onImport)
                    .buttonStyle(.bordered)
            }
        } else if filteredRecordings.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $model.selection) {
                statusSections

                ForEach(filteredRecordings) { recording in
                    RecordingRowView(recording: recording)
                        .tag(recording.id)
                        .contextMenu {
                            Button {
                                beginRename(recording)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                recordingToDelete = recording
                            } label: {
                                Label("Delete Recording", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var filteredRecordings: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.recordings }
        return model.recordings.filter { recording in
            recording.title.localizedCaseInsensitiveContains(query)
                || LibraryFormatting.source(recording.sources).localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if model.isImporting {
            Section {
                Label {
                    Text("Importing audio…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        if let errorMessage = model.errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !model.issues.isEmpty {
            Section("Recovery") {
                ForEach(model.issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { recordingToRename != nil },
            set: { if !$0 { recordingToRename = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { recordingToDelete != nil },
            set: { if !$0 { recordingToDelete = nil } }
        )
    }

    private var deleteMessage: String {
        guard let recording = recordingToDelete else {
            return "This removes the recording and its transcript from this Mac."
        }
        if model.isProcessing(recordingID: recording.id) {
            return "Bardo will stop the current processing task, then permanently remove this recording and its transcript from this Mac."
        }
        return "“\(recording.title)” and its transcript will be permanently removed from this Mac."
    }

    private func beginRename(_ recording: Recording) {
        renameTitle = recording.title
        recordingToRename = recording
    }
}

private struct RecordingRowView: View {
    let recording: Recording

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: LibraryFormatting.sourceSymbol(recording.sources))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text("·")
                    Text(LibraryFormatting.duration(recording.duration))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            stateIndicator
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch recording.processingState {
        case .processing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .partial, .failed:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .pending, .completed:
            EmptyView()
        }
    }

    private var accessibilitySummary: String {
        var values = [
            recording.title,
            LibraryFormatting.source(recording.sources),
            LibraryFormatting.duration(recording.duration)
        ]
        if recording.processingState == .processing
            || recording.processingState == .partial
            || recording.processingState == .failed {
            values.append(LibraryFormatting.state(recording.processingState))
        }
        return values.joined(separator: ", ")
    }
}
