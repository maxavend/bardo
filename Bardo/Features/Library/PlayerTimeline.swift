import SwiftUI

/// The full player's timeline: the recording's named sections along the top, its
/// waveform with the moments marked in it and where the search matched, and the
/// playhead. Click or drag the waveform to jump; click a section or a moment to edit it.
struct PlayerTimeline: View {
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController
    let matches: [TimeInterval]
    let updateNotes: (@escaping (inout RecordingNotes) -> Void) -> Void

    @StateObject private var overview = AudioWaveformOverviewModel()
    @State private var editingMoment: RecordingMoment.ID?
    @State private var editingSection: RecordingSection.ID?

    private static let bandHeight: CGFloat = 24
    private static let waveHeight: CGFloat = 132
    private static let sectionTints: [Color] = [.blue, .purple, .teal, .indigo, .pink]

    private var duration: TimeInterval {
        playback.duration > 0 ? playback.duration : (recording.duration ?? 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    waveform(width: width)
                        .frame(width: width, height: Self.waveHeight)
                        .offset(y: Self.bandHeight + 6)

                    ForEach(Array(recording.notes.sections.enumerated()), id: \.element.id) { index, section in
                        sectionLabel(section, tint: Self.sectionTints[index % Self.sectionTints.count], width: width)
                    }

                    ForEach(recording.notes.moments) { moment in
                        momentFlag(moment, width: width)
                    }
                }
            }
            .frame(height: Self.bandHeight + 6 + Self.waveHeight)

            HStack {
                Text(LibraryFormatting.duration(0))
                Spacer()
                Text(LibraryFormatting.duration(playback.position))
                    .foregroundStyle(.primary)
                Spacer()
                Text(LibraryFormatting.duration(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onAppear { overview.load(playback.loadedTracks) }
        .onChange(of: playback.duration) { _, _ in overview.load(playback.loadedTracks) }
        #if DEBUG
        .onDesignReviewCommand { step in
            if step.action == "editMoment" { editingMoment = recording.notes.moments.first?.id }
            if step.action == "editSection" { editingSection = recording.notes.sections.last?.id }
        }
        #endif
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / duration))) * width
    }

    // MARK: Waveform

    private func waveform(width: CGFloat) -> some View {
        Canvas { canvas, size in
            let levels = overview.levels ?? []
            let step: CGFloat = 3
            let count = max(1, Int(size.width / step))
            let middle = size.height / 2
            let playhead = x(for: playback.position, width: size.width)
            for bar in 0..<count {
                var level: Float = 0
                if !levels.isEmpty {
                    let first = bar * levels.count / count
                    let last = max(first + 1, (bar + 1) * levels.count / count)
                    level = levels[first..<min(last, levels.count)].max() ?? 0
                }
                let half = max(0.75, pow(CGFloat(level), 1.6) * (middle - 6))
                let x = CGFloat(bar) * step
                // What has been heard reads brighter than what is still ahead.
                let opacity = x <= playhead ? 0.8 : 0.35
                canvas.fill(
                    Path(roundedRect: CGRect(x: x, y: middle - half, width: 2, height: half * 2), cornerRadius: 1),
                    with: .color(.primary.opacity(opacity))
                )
            }
            for moment in recording.notes.moments {
                let x = x(for: moment.time, width: size.width)
                canvas.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.orange.opacity(0.8)))
            }
            for match in matches {
                let x = x(for: match, width: size.width)
                canvas.fill(Path(roundedRect: CGRect(x: x - 2, y: size.height - 6, width: 4, height: 6), cornerRadius: 2), with: .color(.yellow))
            }
            canvas.fill(
                Path(roundedRect: CGRect(x: playhead - 2, y: -4, width: 4, height: size.height + 8), cornerRadius: 2),
                with: .color(.accentColor)
            )
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                playback.seek(to: Double(min(1, max(0, value.location.x / width))) * duration)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Posición en la grabación"))
        .accessibilityValue(Text(LibraryFormatting.duration(playback.position)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.seek(to: playback.position + 10)
            case .decrement: playback.seek(to: playback.position - 10)
            @unknown default: break
            }
        }
    }

    // MARK: Sections

    private func sectionLabel(_ section: RecordingSection, tint: Color, width: CGFloat) -> some View {
        let start = x(for: section.start, width: width)
        let end = x(for: recording.notes.end(of: section, duration: duration) ?? duration, width: width)
        return Button {
            editingSection = section.id
        } label: {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: max(24, end - start - 2), height: Self.bandHeight, alignment: .leading)
                .background(tint.opacity(0.18), in: .rect(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    Rectangle().fill(tint).frame(width: 2)
                }
                .clipShape(.rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(section.title) · desde \(LibraryFormatting.duration(section.start))")
        .offset(x: start)
        .popover(isPresented: Binding(
            get: { editingSection == section.id },
            set: { if !$0 { editingSection = nil } }
        ), arrowEdge: .bottom) {
            SectionEditor(section: section) { change in
                updateNotes(change)
                editingSection = nil
            }
        }
    }

    // MARK: Moments

    private func momentFlag(_ moment: RecordingMoment, width: CGFloat) -> some View {
        Button {
            editingMoment = moment.id
        } label: {
            Image(systemName: "flag.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(moment.title) · \(LibraryFormatting.duration(moment.time))")
        .offset(x: x(for: moment.time, width: width) - 4, y: Self.bandHeight + 4)
        .popover(isPresented: Binding(
            get: { editingMoment == moment.id },
            set: { if !$0 { editingMoment = nil } }
        ), arrowEdge: .bottom) {
            MomentEditor(moment: moment, seek: { playback.seek(to: moment.time) }) { change in
                updateNotes(change)
                editingMoment = nil
            }
        }
    }
}

/// Edits a saved moment's title and note, or removes it.
private struct MomentEditor: View {
    let moment: RecordingMoment
    let seek: () -> Void
    let apply: (@escaping (inout RecordingNotes) -> Void) -> Void

    @State private var title: String
    @State private var note: String

    init(moment: RecordingMoment, seek: @escaping () -> Void, apply: @escaping (@escaping (inout RecordingNotes) -> Void) -> Void) {
        self.moment = moment
        self.seek = seek
        self.apply = apply
        _title = State(initialValue: moment.title)
        _note = State(initialValue: moment.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Momento · \(LibraryFormatting.duration(moment.time))", systemImage: "flag.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Ir", action: seek)
                    .controlSize(.small)
            }
            TextField("Título", text: $title, prompt: Text(RecordingMoment.defaultTitle(at: moment.time)))
                .textFieldStyle(.roundedBorder)
            TextField("Nota", text: $note, prompt: Text("Nota (opcional)"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Button("Eliminar", role: .destructive) {
                    let id = moment.id
                    apply { $0.removeMoment(id) }
                }
                Spacer()
                Button("Guardar") {
                    let (id, title, note) = (moment.id, title, note)
                    apply { $0.editMoment(id, title: title, note: note) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Renames a saved section or removes it; the audio is never cut.
private struct SectionEditor: View {
    let section: RecordingSection
    let apply: (@escaping (inout RecordingNotes) -> Void) -> Void

    @State private var title: String

    init(section: RecordingSection, apply: @escaping (@escaping (inout RecordingNotes) -> Void) -> Void) {
        self.section = section
        self.apply = apply
        _title = State(initialValue: section.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sección desde \(LibraryFormatting.duration(section.start))", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.headline)
            TextField("Nombre", text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Eliminar", role: .destructive) {
                    let id = section.id
                    apply { $0.removeSection(id) }
                }
                Spacer()
                Button("Guardar") {
                    let (id, title) = (section.id, title)
                    apply { $0.renameSection(id, to: title) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
