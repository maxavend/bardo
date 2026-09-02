import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var model: LibraryViewModel
    let onImport: () -> Void

    var body: some View {
        content
            .navigationTitle("Bardo")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
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
                Text("Record something, import an audio file, or drop audio into this window.")
            } actions: {
                Button("Import Audio", action: onImport)
            }
        } else {
            List(selection: $model.selection) {
                statusSections

                Section("Recordings") {
                    ForEach(model.recordings) { recording in
                        RecordingRowView(recording: recording, model: model)
                            .tag(recording.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if let feedback = model.recordingActionFeedback {
            Section("Done") {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let actionError = model.recordingActionErrorMessage {
            Section("Action Needs Attention") {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

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
            Section("Library") {
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
}

private struct RecordingRowView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: LibraryFormatting.sourceSymbol(recording.sources))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                        .font(.caption)
                        .foregroundStyle(recording.processingState == .failed ? .primary : .secondary)
                        .accessibilityLabel(LibraryFormatting.state(recording.processingState))
                }

                Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(LibraryFormatting.duration(recording.duration))
                        .monospacedDigit()
                    Text("·")
                    Text(LibraryFormatting.source(recording.sources))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard RecordingActionPolicy.allows(.playPause, for: recording) else { return }
            Task { await model.playRecording(recording.id) }
        }
        .contextMenu {
            if RecordingActionPolicy.allows(.playPause, for: recording) {
                Button {
                    Task { await model.playRecording(recording.id) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }

            Divider()

            Button {
                isRenamePresented = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(model.isTranscribing || model.isDiarizing)

            Button {
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label("Copy Location", systemImage: "doc.on.doc")
            }

            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        .sheet(isPresented: $isRenamePresented) {
            RecordingRenameSheet(
                recording: recording,
                onSave: { title in
                    isRenamePresented = false
                    Task { await model.renameRecording(recording.id, to: title) }
                },
                onCancel: { isRenamePresented = false }
            )
        }
        .confirmationDialog(
            "Move Recording to Trash?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteRecording(recording.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the managed audio, transcript, and minutes for \"\(recording.title)\" to the macOS Trash, where you can recover it.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(recording.title), \(LibraryFormatting.source(recording.sources)), \(LibraryFormatting.duration(recording.duration)), \(LibraryFormatting.state(recording.processingState))"
        )
    }

    private func revealInFinder() {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError("Bardo could not locate the managed recording folder.")
                return
            }
            let target = FileManager.default.fileExists(atPath: location.path)
                ? location
                : location.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
