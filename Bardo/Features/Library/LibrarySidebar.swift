import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel
    @Binding var searchText: String
    let onImport: () -> Void

    var body: some View {
        content
            .navigationTitle(String(localized: "Library"))
            .navigationSplitViewColumnWidth(
                min: BardoLayout.librarySidebarMinWidth,
                ideal: BardoLayout.librarySidebarIdealWidth,
                max: BardoLayout.librarySidebarMaxWidth
            )
            .enableInjection()
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.recordings.isEmpty {
            ProgressView(String(localized: "Loading Recordings…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isImporting && model.recordings.isEmpty {
            ProgressView(String(localized: "Importing Audio…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.recordings.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Library Unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty && !model.issues.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Library Needs Recovery"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(String.localizedStringWithFormat(
                    String(localized: "%lld stored items could not be loaded. Bardo left them untouched."),
                    model.issues.count
                ))
            } actions: {
                Button(String(localized: "Reload")) {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Recordings"), systemImage: "waveform")
            } description: {
                Text(String(localized: "Record something, import an audio file, or drop audio into this window."))
            } actions: {
                Button(String(localized: "Import Audio"), action: onImport)
            }
        } else if filteredRecordings.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $model.selection) {
                statusSections

                Section(String(localized: "Recordings")) {
                    ForEach(filteredRecordings) { recording in
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
            Section {
                Label(feedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let actionError = model.recordingActionErrorMessage {
            Section {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if model.isImporting {
            Section {
                Label {
                    Text(String(localized: "Importing audio…"))
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
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !model.issues.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(Array(model.issues.prefix(3))) { issue in
                        RecoveryIssueSidebarRow(issue: issue)
                    }

                    if model.issues.count > 3 {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "%lld more items"),
                                model.issues.count - 3
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                    }
                } label: {
                    Label(
                        String.localizedStringWithFormat(
                            String(localized: "%lld items need review"),
                            model.issues.count
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filteredRecordings: [Recording] {
        model.recordings.filter { RecordingSearch.matches($0, query: searchText) }
    }
}

private struct RecoveryIssueSidebarRow: View {
    let issue: RecordingStoreIssue

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help("\(detail)\n\(issue.message)\n\(issue.entryName)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var title: String {
        switch issue.kind {
        case .corruptManifest, .missingManifest, .identityMismatch:
            return String(localized: "Incomplete recording")
        case .unsupportedSchemaVersion:
            return String(localized: "Recording from a newer version")
        case .temporaryArtifact, .temporaryAudioArtifact:
            return String(localized: "Interrupted capture")
        case .missingAudioFile, .missingDerivedAudioFile:
            return String(localized: "Audio unavailable")
        case .unexpectedEntry, .unreadableEntry:
            return String(localized: "Recording needs attention")
        }
    }

    private var detail: String {
        switch issue.kind {
        case .corruptManifest, .missingManifest, .identityMismatch:
            return String(localized: "Bardo couldn't recover all of this recording's information.")
        case .unsupportedSchemaVersion:
            return String(localized: "Update Bardo to open this recording.")
        case .temporaryArtifact, .temporaryAudioArtifact:
            return String(localized: "The interrupted capture was preserved safely.")
        case .missingAudioFile, .missingDerivedAudioFile:
            return String(localized: "The recording metadata is safe, but its audio file is missing.")
        case .unexpectedEntry, .unreadableEntry:
            return String(localized: "Bardo left this item untouched for review.")
        }
    }

    private var symbol: String {
        switch issue.kind {
        case .temporaryArtifact, .temporaryAudioArtifact:
            return "clock.arrow.circlepath"
        case .missingAudioFile, .missingDerivedAudioFile:
            return "waveform.badge.exclamationmark"
        default:
            return "exclamationmark.triangle"
        }
    }
}

private struct RecordingRowView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false

    private var isPlaying: Bool {
        model.selection == recording.id && model.playback.isPlaying
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "waveform")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(LibraryFormatting.recordingTitle(recording))
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            stateIcon
        }
        .padding(.vertical, 2)
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
                    Label(
                        isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                }
            }

            Divider()

            Button {
                isRenamePresented = true
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
            .disabled(model.isTranscribing || model.isDiarizing)

            Button {
                revealInFinder()
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "folder")
            }

            Button {
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label(String(localized: "Copy Location"), systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(String(localized: "Move to Trash"), systemImage: "trash")
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
            String(localized: "Move Recording to Trash?"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash"), role: .destructive) {
                Task { await model.deleteRecording(recording.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "This moves the managed audio, transcript, and minutes for \"%@\" to the macOS Trash, where you can recover it."),
                LibraryFormatting.recordingTitle(recording)
            ))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(LibraryFormatting.recordingTitle(recording)), \(recording.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())), \(LibraryFormatting.source(recording.sources)), \(LibraryFormatting.duration(recording.duration)), \(LibraryFormatting.state(recording.processingState))"
        )
        .help("\(recording.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(LibraryFormatting.duration(recording.duration))")
    }

    private var metadata: String {
        "\(recording.createdAt.formatted(.dateTime.day().month(.abbreviated))) · \(LibraryFormatting.duration(recording.duration))"
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch recording.processingState {
        case .pending:
            EmptyView()
        case .processing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .completed:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .foregroundStyle(.secondary)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .failed:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .foregroundStyle(.orange)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        }
    }

    private func revealInFinder() {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError(String(localized: "Bardo could not locate the managed recording folder."))
                return
            }
            let target = FileManager.default.fileExists(atPath: location.path)
                ? location
                : location.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}