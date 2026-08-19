import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Library")
                .toolbar {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import Audio", systemImage: "plus")
                    }
                    .disabled(model.isImporting)

                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading || model.isImporting)
                }
        } detail: {
            detail
        }
        .task {
            await model.reload()
        }
        .task(id: model.selection) {
            await model.preparePlaybackForSelection()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importAudio(from: urls) }
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isImporting, !urls.isEmpty else { return false }
            Task { await model.importAudio(from: urls) }
            return true
        }
        .alert(
            "Audio Import Failed",
            isPresented: Binding(
                get: { model.importErrorMessage != nil },
                set: { if !$0 { model.clearImportError() } }
            )
        ) {
            Button("OK") { model.clearImportError() }
        } message: {
            Text(model.importErrorMessage ?? "The audio could not be imported.")
        }
        .onDisappear {
            model.stopPlayback()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.isLoading && model.recordings.isEmpty {
            ProgressView("Loading Library…")
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
                Text("Import a compatible audio file or drop one into this window.")
            } actions: {
                Button("Import Audio") {
                    isFileImporterPresented = true
                }
            }
        } else {
            List(selection: $model.selection) {
                if model.isImporting {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing audio…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section("Library Error") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
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
            RecordingDetail(recording: recording, playback: model.playback)
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
    @ObservedObject var playback: AudioPlaybackController

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

            if let asset = recording.audioAssets.first {
                Section("Audio") {
                    LabeledContent("Original file", value: asset.originalFileName)
                    LabeledContent("Codec", value: asset.metadata.codec)
                    LabeledContent("Sample rate", value: sampleRateText(asset.metadata.sampleRate))
                    LabeledContent("Channels", value: String(asset.metadata.channelCount))
                }

                Section("Playback") {
                    if let errorMessage = playback.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            playback.togglePlayback()
                        } label: {
                            Label(
                                playback.isPlaying ? "Pause" : "Play",
                                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .disabled(!playback.isLoaded)

                        Slider(
                            value: Binding(
                                get: { playback.position },
                                set: { playback.seek(to: $0) }
                            ),
                            in: 0...max(playback.duration, 0.01)
                        )
                        .disabled(!playback.isLoaded)

                        Text("\(durationText(playback.position)) / \(durationText(playback.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Audio") {
                    ContentUnavailableView(
                        "No Managed Audio",
                        systemImage: "waveform.slash",
                        description: Text("This recording predates audio import or has no managed audio resource.")
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(recording.title)
    }
}

private func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "Unknown" }
    return durationText(duration)
}

private func durationText(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func sampleRateText(_ sampleRate: Double) -> String {
    if sampleRate >= 1_000 {
        return String(format: "%.1f kHz", sampleRate / 1_000)
    }
    return String(format: "%.0f Hz", sampleRate)
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
