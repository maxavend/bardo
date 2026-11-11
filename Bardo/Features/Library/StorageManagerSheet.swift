import AppKit
import SwiftUI

/// What Bardo keeps on this Mac and what each conversation takes, largest first, with
/// the two ways to free space: compressing audio and moving conversations to the Trash.
struct StorageManagerSheet: View {
    @ObservedObject var model: LibraryViewModel
    /// Moves conversations to the Trash the way the Library does, once confirmed here.
    let moveToTrash: (Set<Recording.ID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var report: LibraryStorageReport?
    @State private var selection: Set<Recording.ID> = []
    @State private var sortOrder = [KeyPathComparator(\StorageRow.bytes, order: .reverse)]
    @State private var compressionRequest: CompressionRequest?
    @State private var trashCandidates: Set<Recording.ID> = []
    @State private var showsTrackDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)

            if model.recordings.isEmpty {
                ContentUnavailableView(
                    "Sin conversaciones",
                    systemImage: "externaldrive",
                    description: Text("Las grabaciones y el audio importado aparecerán aquí con lo que ocupan.")
                )
                .frame(maxHeight: .infinity)
            } else {
                if let recommendation {
                    recommendationRow(recommendation)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }
                tableHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                table
                    .padding(.horizontal, 24)
            }

            footer
        }
        .frame(width: 800)
        .frame(minHeight: 460, idealHeight: 620)
        .task(id: model.recordings) {
            report = await model.storageReport()
            selection.formIntersection(model.recordings.map(\.id))
        }
        .sheet(item: $compressionRequest) { request in
            CompressAudioSheet(recordingIDs: request.ids, model: model)
        }
        .onChange(of: selection) { _, _ in showsTrackDetails = false }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(
                get: { !trashCandidates.isEmpty },
                set: { if !$0 { trashCandidates = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                let ids = trashCandidates
                selection.subtract(ids)
                moveToTrash(ids)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Sus audios y transcripciones se moverán a la Papelera de macOS, donde podrás recuperarlos.")
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "storageSelect":
                // `storageSelect:0,1` selects rows in table order.
                let rows = sortedRows
                let indices = step.value.split(separator: ",").compactMap { Int($0) }
                selection = Set(indices.filter { rows.indices.contains($0) }.map { rows[$0].id })
            case "storageCompress":
                if !selection.isEmpty { compress(selection) }
            case "storageTracks":
                showsTrackDetails = selectedRecording != nil
            case "storageRecommendation":
                if let recommendation { compress(Set(recommendation.ids)) }
            default:
                break
            }
        }
        #endif
    }

    // MARK: Summary

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Almacenamiento")
                    .font(.title2.weight(.semibold))
                Group {
                    if let report {
                        Text(summary(report))
                    } else {
                        Text("Calculando…")
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if let report, report.totalBytes > 0 {
                StorageUsageBar(segments: segments(report))
            }
        }
    }

    private func summary(_ report: LibraryStorageReport) -> String {
        let used = "Bardo usa \(LibraryStorage.format(report.totalBytes))"
        guard let available = report.availableBytes else { return used }
        return "\(used) · \(LibraryStorage.format(available)) disponibles en este Mac"
    }

    private func segments(_ report: LibraryStorageReport) -> [StorageUsageBar.Segment] {
        [
            .init(title: "Audio", bytes: report.audioBytes, color: .accentColor),
            .init(title: "Transcripciones y notas", bytes: report.otherLibraryBytes, color: .orange),
            .init(title: "Recursos para transcribir", bytes: report.modelsBytes, color: .gray)
        ]
    }

    // MARK: Recommendation

    private struct Recommendation {
        let ids: [Recording.ID]
        let savedBytes: Int64
    }

    /// The conversations whose audio would shrink the most at Equilibrada: worth it
    /// only when it frees a meaningful amount.
    private var recommendation: Recommendation? {
        guard let report else { return nil }
        let bytes = report.allAudioBytes
        var ids: [Recording.ID] = []
        var saved: Int64 = 0
        for recording in model.recordings where !model.isProcessing(recording.id) {
            let plan = AudioCompressionPlan(recordings: [recording], audioBytes: bytes, mergeTracks: true)
            guard plan.savesSpace, plan.savedBytes >= Self.recommendationMinimumBytes else { continue }
            ids.append(recording.id)
            saved += plan.savedBytes
        }
        guard !ids.isEmpty else { return nil }
        let order = sortedRows.map(\.id)
        ids.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        return Recommendation(ids: ids, savedBytes: saved)
    }

    private static let recommendationMinimumBytes: Int64 = 5_000_000

    private func recommendationRow(_ recommendation: Recommendation) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comprime el audio más pesado")
                        .font(.headline)
                    Text(recommendation.ids.count == 1
                        ? "Una conversación puede ocupar unos \(LibraryStorage.format(recommendation.savedBytes)) menos."
                        : "\(recommendation.ids.count) conversaciones pueden ocupar unos \(LibraryStorage.format(recommendation.savedBytes)) menos.")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Comprimir…") { compress(Set(recommendation.ids)) }
                    .disabled(model.compressionRun?.isRunning == true)
            }
        }
    }

    // MARK: Conversations

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("Conversaciones")
                .font(.headline)
            Spacer()
            Button("Pistas…") { showsTrackDetails = true }
                .disabled(selectedRecording.flatMap { report?.entries[$0.id] } == nil)
                .popover(isPresented: $showsTrackDetails, arrowEdge: .bottom) {
                    if let recording = selectedRecording, let entry = report?.entries[recording.id] {
                        trackDetails(recording, entry: entry)
                    }
                }
            Button("Comprimir…") { compress(selection) }
                .disabled(selection.isEmpty || model.compressionRun?.isRunning == true)
            Button("Mover a la Papelera…") { trashCandidates = selection }
                .disabled(selection.isEmpty)
        }
    }

    private var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Conversación", value: \.title) { row in
                HStack(spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.title)
                    if row.isArchived {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.secondary)
                            .help("Archivada")
                            .accessibilityLabel("Archivada")
                    }
                }
            }
            .width(min: 160, ideal: 230)

            TableColumn("Fecha", value: \.date) { row in
                Text(row.date, format: .dateTime.day().month(.abbreviated).year())
            }
            .width(min: 90, ideal: 100)

            TableColumn("Duración", value: \.duration) { row in
                Text(LibraryFormatting.duration(row.duration))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("Formato", value: \.format) { row in
                Text(row.format)
            }
            .width(min: 56, ideal: 64)

            TableColumn("Pistas", value: \.trackCount) { row in
                Text(row.trackCount, format: .number)
                    .monospacedDigit()
            }
            .width(min: 45, ideal: 50)

            TableColumn("Tamaño", value: \.bytes) { row in
                Text(row.bytes > 0 ? LibraryStorage.format(row.bytes) : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Comprimida", value: \.compressedSortKey) { row in
                Group {
                    if let compressed = row.compressedBytes {
                        Text("unos \(LibraryStorage.format(compressed))")
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                            .help("Ya ocupa poco")
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 84, ideal: 96)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Recording.ID.self) { ids in
            if !ids.isEmpty {
                Button {
                    compress(ids)
                } label: {
                    Label("Comprimir audio…", systemImage: "rectangle.compress.vertical")
                }
                .disabled(model.compressionRun?.isRunning == true)
                Button {
                    reveal(ids)
                } label: {
                    Label("Mostrar en Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    trashCandidates = ids
                } label: {
                    Label("Mover a la Papelera…", systemImage: "trash")
                }
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty { trashCandidates = selection }
        }
    }

    private var selectedRecording: Recording? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.recordings.first { $0.id == id }
    }

    private func trackDetails(_ recording: Recording, entry: LibraryStorageReport.Entry) -> some View {
        let merge = AudioCompressionPlan(recordings: [recording], audioBytes: entry.audioBytes, mergeTracks: true)
        return VStack(alignment: .leading, spacing: 10) {
            Text(LibraryFormatting.recordingTitle(recording))
                .font(.headline)
                .lineLimit(2)
            AudioTrackSizeRows(recording: recording, bytes: entry.audioBytes)
            Divider()
            LabeledContent("Total de audio", value: LibraryStorage.format(entry.audioTotal))
            LabeledContent("Total de la conversación", value: LibraryStorage.format(entry.totalBytes))
            if AudioCompressionMix(recording: recording) != nil {
                LabeledContent("Una pista a 24 kbps", value: "≈ \(LibraryStorage.format(merge.copyBytes))")
                Button("Unir y comprimir…") {
                    showsTrackDetails = false
                    compress([recording.id])
                }
                .disabled(model.isProcessing(recording.id) || model.compressionRun?.isRunning == true)
            }
        }
        .padding(16)
        .frame(width: 320)
        .monospacedDigit()
        .labeledContentStyle(StorageTrackDetailStyle())
    }

    private var footer: some View {
        HStack {
            Text(footerSummary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Listo") { dismiss() }
                .bardoPrimaryAction()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footerSummary: String {
        let rows = sortedRows
        let chosen = selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
        let bytes = LibraryStorage.format(chosen.reduce(0) { $0 + $1.bytes })
        if selection.isEmpty {
            return rows.count == 1 ? "1 conversación · \(bytes)" : "\(rows.count) conversaciones · \(bytes)"
        }
        return chosen.count == 1 ? "1 seleccionada · \(bytes)" : "\(chosen.count) seleccionadas · \(bytes)"
    }

    // MARK: Rows and actions

    private var sortedRows: [StorageRow] {
        let entries = report?.entries ?? [:]
        let bytes = report?.allAudioBytes ?? [:]
        let rows = model.recordings.map { recording in
            let plan = AudioCompressionPlan(recordings: [recording], audioBytes: bytes, mergeTracks: true)
            let entry = entries[recording.id]
            let audio = entry?.audioTotal ?? 0
            return StorageRow(
                id: recording.id,
                title: LibraryFormatting.recordingTitle(recording),
                date: recording.createdAt,
                duration: recording.duration ?? 0,
                format: Self.format(of: recording),
                trackCount: recording.audioAssets.count,
                bytes: entry?.totalBytes ?? 0,
                compressedBytes: plan.savesSpace ? (entry?.totalBytes ?? audio) - plan.savedBytes : nil,
                isArchived: recording.isArchived
            )
        }
        return rows.sorted(using: sortOrder)
    }

    private static func format(of recording: Recording) -> String {
        var formats: [String] = []
        for asset in recording.audioAssets {
            let format = asset.fileExtension.uppercased()
            if !formats.contains(format) { formats.append(format) }
        }
        return formats.isEmpty ? "—" : formats.joined(separator: ", ")
    }

    private var trashTitle: String {
        if trashCandidates.count == 1,
           let recording = model.recordings.first(where: { trashCandidates.contains($0.id) }) {
            return "¿Mover «\(LibraryFormatting.recordingTitle(recording))» a la Papelera?"
        }
        return "¿Mover \(trashCandidates.count) conversaciones a la Papelera?"
    }

    private func compress(_ ids: Set<Recording.ID>) {
        let order = sortedRows.map(\.id)
        compressionRequest = CompressionRequest(ids: order.filter { ids.contains($0) })
    }

    private func reveal(_ ids: Set<Recording.ID>) {
        Task {
            var urls: [URL] = []
            for id in ids {
                if let url = try? await model.managedLocation(for: id) { urls.append(url) }
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }
}

private struct StorageTrackDetailStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
        }
    }
}

/// Conversations to compress, for presenting `CompressAudioSheet`.
struct CompressionRequest: Identifiable {
    let id = UUID()
    let ids: [Recording.ID]
}

struct StorageRow: Identifiable {
    let id: Recording.ID
    let title: String
    let date: Date
    let duration: TimeInterval
    let format: String
    let trackCount: Int
    let bytes: Int64
    /// What the conversation would take compressed at Equilibrada; `nil` when it would
    /// not shrink.
    let compressedBytes: Int64?
    let isArchived: Bool

    var compressedSortKey: Int64 { compressedBytes ?? bytes }
}

/// A slim bar of what Bardo's space is made of, with a legend that names each part, as
/// in System Settings › Storage.
struct StorageUsageBar: View {
    struct Segment: Identifiable {
        let title: String
        let bytes: Int64
        let color: Color

        var id: String { title }
    }

    let segments: [Segment]

    private var total: Int64 { max(1, segments.reduce(0) { $0 + $1.bytes }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.bytes > 0 }) { segment in
                        segment.color
                            .frame(width: max(3, proxy.size.width * CGFloat(segment.bytes) / CGFloat(total)))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .background(Capsule().fill(.quaternary))
            .accessibilityHidden(true)

            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(segment.title)
                        Text(LibraryStorage.format(segment.bytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
