import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel
    @Binding var searchText: String
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarControls
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.85))
        .navigationTitle("")
        .navigationSplitViewColumnWidth(
            min: BardoLayout.librarySidebarMinWidth,
            ideal: BardoLayout.librarySidebarIdealWidth,
            max: BardoLayout.librarySidebarMaxWidth
        )
        .enableInjection()
    }

    private var sidebarControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField(String(localized: "Buscar"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .bardoGlassCapsule(interactive: true)

            sidebarActionButton(systemImage: "square.and.arrow.up", label: String(localized: "Import Audio"))
            sidebarActionButton(systemImage: "plus", label: String(localized: "Import Audio"))
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .controlSize(.regular)
    }

    private func sidebarActionButton(systemImage: String, label: String) -> some View {
        Button(action: onImport) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .bardoGlassCircle(interactive: true)
        }
        .buttonStyle(.bardoPressable)
        .disabled(model.isImporting || model.isTranscribing || model.isDiarizing)
        .help(label)
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
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if let feedback = model.recordingActionFeedback {
            Section(String(localized: "Done")) {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let actionError = model.recordingActionErrorMessage {
            Section(String(localized: "Action Needs Attention")) {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
            Section(String(localized: "Library")) {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        if !model.issues.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(model.issues) { issue in
                        RecoveryIssueSidebarRow(issue: issue)
                    }
                } label: {
                    Label(
                        String.localizedStringWithFormat(String(localized: "%lld Recovery Items"), model.issues.count),
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(formattedEntryName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(issue.message)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(formattedEntryName)")
    }

    private var formattedEntryName: String {
        let name = issue.entryName
        if name.hasPrefix("Recording ") {
            let idPart = String(name.dropFirst("Recording ".count))
            return idPart.count > 8 ? "\(idPart.prefix(8))…" : idPart
        }
        if let uuid = UUID(uuidString: name) {
            return "\(uuid.uuidString.prefix(8))…"
        }
        return name
    }

    private var title: String {
        switch issue.kind {
        case .corruptManifest:
            return String(localized: "Corrupt manifest")
        case .missingManifest:
            return String(localized: "Missing manifest")
        case .unsupportedSchemaVersion:
            return String(localized: "Unsupported recording")
        case .identityMismatch:
            return String(localized: "Identity mismatch")
        case .temporaryArtifact, .temporaryAudioArtifact:
            return String(localized: "Interrupted capture")
        case .missingAudioFile, .missingDerivedAudioFile:
            return String(localized: "Missing audio")
        case .unexpectedEntry:
            return String(localized: "Unexpected file")
        case .unreadableEntry:
            return String(localized: "Unreadable file")
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

    private var isSelected: Bool {
        model.selection == recording.id
    }

    private var isPlaying: Bool {
        isSelected && model.playback.isPlaying
    }

    var body: some View {
        HStack(spacing: 8) {
            sourceIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(LibraryFormatting.recordingTitle(recording))
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(recording.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                    Text("·")
                    Text(LibraryFormatting.duration(recording.duration))
                }
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.8))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            stateIcon
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
                    Label(String(localized: "Play"), systemImage: "play.fill")
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
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label(String(localized: "Copy Location"), systemImage: "doc.on.doc")
            }

            Button {
                revealInFinder()
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "folder")
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

    private var sourceIcon: some View {
        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "waveform")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isSelected ? Color.cyan : Color.cyan.opacity(0.75))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch recording.processingState {
        case .pending:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .processing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .completed:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(LibraryFormatting.state(recording.processingState))
        case .failed:
            Image(systemName: LibraryFormatting.stateSymbol(recording.processingState))
                .font(.caption)
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
