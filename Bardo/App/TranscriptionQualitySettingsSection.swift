import SwiftUI

struct TranscriptionQualitySettingsSection: View {
    @AppStorage(TranscriptionQuality.storageKey)
    private var qualityRaw = TranscriptionQuality.preferredDefault.rawValue

    @State private var modelStates: [TranscriptionQuality: TranscriptionModelState] = [:]
    @State private var activeDownload: TranscriptionQuality?
    @State private var downloadProgress: Double = 0
    @State private var pendingRemoval: TranscriptionQuality?
    @State private var errorMessage: String?

    private var selectedQuality: TranscriptionQuality {
        TranscriptionQuality.resolve(qualityRaw)
    }

    var body: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(TranscriptionQuality.allCases) { quality in
                    qualityRow(quality)

                    if quality != TranscriptionQuality.allCases.last {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
        } header: {
            Text("Transcription Quality", tableName: "TranscriptUI")
        } footer: {
            Text(
                "Choose speed or accuracy, not a technical model. The change is used for future transcriptions and when you transcribe again.",
                tableName: "TranscriptUI"
            )
        }

        Section {
            ForEach(TranscriptionQuality.allCases) { quality in
                modelRow(quality)
            }
        } header: {
            Text("Downloaded Models", tableName: "TranscriptUI")
        } footer: {
            Text(
                "Bardo downloads only the models you use. Model files stay on this Mac and can be removed at any time.",
                tableName: "TranscriptUI"
            )
        }
        .task {
            await refreshModelStates()
        }
        .alert(
            Text("Remove Downloaded Model?", tableName: "TranscriptUI"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button(role: .cancel) {
                pendingRemoval = nil
            } label: {
                Text("Cancel", tableName: "TranscriptUI")
            }

            Button(role: .destructive) {
                guard let quality = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await removeModel(quality) }
            } label: {
                Text("Remove", tableName: "TranscriptUI")
            }
        } message: {
            Text(
                "The model can be downloaded again automatically the next time you use this quality.",
                tableName: "TranscriptUI"
            )
        }
        .alert(
            Text("Model Couldn’t Be Changed", tableName: "TranscriptUI"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func qualityRow(_ quality: TranscriptionQuality) -> some View {
        Button {
            qualityRaw = quality.rawValue
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedQuality == quality ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selectedQuality == quality ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(titleKey(for: quality), tableName: "TranscriptUI")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        if quality == .balanced {
                            Text("Recommended", tableName: "TranscriptUI")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    Text(descriptionKey(for: quality), tableName: "TranscriptUI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if quality == .maximum {
                        Text(maximumHardwareNoteKey, tableName: "TranscriptUI")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(titleKey(for: quality), tableName: "TranscriptUI"))
        .accessibilityValue(
            selectedQuality == quality
                ? Text("Selected", tableName: "TranscriptUI")
                : Text("")
        )
    }

    private func modelRow(_ quality: TranscriptionQuality) -> some View {
        let state = modelStates[quality]
        let isDownloading = activeDownload == quality

        return HStack(spacing: 12) {
            Image(systemName: quality == .instant ? "bolt.fill" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey(for: quality), tableName: "TranscriptUI")
                    .font(.body.weight(.medium))

                HStack(spacing: 5) {
                    Text(quality.engineDisplayName)
                    Text("·")
                    Text(storageDescription(for: quality, state: state))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if isDownloading {
                ProgressView(value: downloadProgress)
                    .frame(width: 72)
                    .accessibilityLabel(Text("Downloading Model", tableName: "TranscriptUI"))
            } else if state?.isInstalled == true {
                Button(role: .destructive) {
                    pendingRemoval = quality
                } label: {
                    Text("Remove…", tableName: "TranscriptUI")
                }
            } else {
                Button {
                    Task { await downloadModel(quality) }
                } label: {
                    Text("Download", tableName: "TranscriptUI")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func titleKey(for quality: TranscriptionQuality) -> LocalizedStringKey {
        switch quality {
        case .instant:
            "Instant"
        case .balanced:
            "Balanced"
        case .maximum:
            "Maximum Accuracy"
        }
    }

    private func descriptionKey(for quality: TranscriptionQuality) -> LocalizedStringKey {
        switch quality {
        case .instant:
            "Prioritizes speed. Ideal for long meetings and near-immediate results. Context hints are limited in this mode."
        case .balanced:
            "Excellent accuracy without sacrificing speed. Best for most recordings."
        case .maximum:
            "Prioritizes accuracy for difficult audio, names, and multilingual speech."
        }
    }

    private var maximumHardwareNoteKey: LocalizedStringKey {
        if ProcessInfo.processInfo.physicalMemory >= 16_000_000_000 {
            return "Your Mac can run this model comfortably."
        }
        return "Uses more memory and may take longer on this Mac."
    }

    private func storageDescription(
        for quality: TranscriptionQuality,
        state: TranscriptionModelState?
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        if state?.isInstalled == true {
            if let bytes = state?.sizeBytes {
                return "\(LibraryFormatting.localized("Installed")) · \(formatter.string(fromByteCount: bytes))"
            }
            return LibraryFormatting.localized("Installed")
        }

        let approximate = formatter.string(fromByteCount: quality.approximateDownloadBytes)
        return String(
            format: LibraryFormatting.localized("About %@"),
            approximate
        )
    }

    @MainActor
    private func refreshModelStates() async {
        do {
            let service = try BardoTranscriptionService.live()
            var states: [TranscriptionQuality: TranscriptionModelState] = [:]
            for quality in TranscriptionQuality.allCases {
                states[quality] = await service.modelState(for: quality)
            }
            modelStates = states
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func downloadModel(_ quality: TranscriptionQuality) async {
        guard activeDownload == nil else { return }
        activeDownload = quality
        downloadProgress = 0
        defer {
            activeDownload = nil
            downloadProgress = 0
        }

        do {
            let service = try BardoTranscriptionService.live()
            try await service.downloadModel(for: quality) { snapshot in
                Task { @MainActor in
                    guard activeDownload == quality else { return }
                    downloadProgress = max(downloadProgress, snapshot.fractionCompleted)
                }
            }
            await refreshModelStates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeModel(_ quality: TranscriptionQuality) async {
        do {
            let service = try BardoTranscriptionService.live()
            try await service.removeModel(for: quality)
            await refreshModelStates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
