import SwiftUI

/// The full player's timeline: the recording's sections named along the top like
/// chapters on a ruler, its waveform drawn like the recorder, the moments marked in it
/// and where the search matched. Click or drag the waveform to jump; click a section's
/// name or a moment's dot to edit it.
struct PlayerTimeline: View {
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController
    let matches: [TimeInterval]
    let updateNotes: (@escaping (inout RecordingNotes) -> Void) -> Void

    @State private var editingMoment: RecordingMoment.ID?
    @State private var editingSection: RecordingSection.ID?

    private static let laneHeight: CGFloat = 22
    private static let waveHeight: CGFloat = 150

    private var duration: TimeInterval {
        playback.duration > 0 ? playback.duration : (recording.duration ?? 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    RecordingWaveform(recording: recording, playback: playback, matches: matches, labelsSections: false)
                        .frame(width: width, height: Self.waveHeight)
                        .offset(y: Self.laneHeight + 8)

                    ForEach(recording.notes.sections) { section in
                        sectionLabel(section, width: width)
                    }

                    ForEach(recording.notes.moments) { moment in
                        momentTarget(moment, width: width)
                    }
                }
            }
            .frame(height: Self.laneHeight + 8 + Self.waveHeight)

            HStack {
                Text(LibraryFormatting.duration(playback.position))
                    .foregroundStyle(.primary)
                Spacer()
                Text("-" + LibraryFormatting.duration(max(0, duration - playback.position)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            if step.action == "editMoment" { editingMoment = recording.notes.moments.first?.id }
            if step.action == "editSection" { editingSection = recording.notes.sections.last?.id }
        }
        #endif
    }

    /// The same mapping as the waveform, so labels and dots sit on what it draws.
    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let inset = RecordingWaveform.inset
        guard duration > 0 else { return inset }
        return inset + CGFloat(min(1, max(0, time / duration))) * (width - inset * 2)
    }

    // MARK: Sections

    /// A section's name where it starts, in full colour while it plays.
    private func sectionLabel(_ section: RecordingSection, width: CGFloat) -> some View {
        let start = x(for: section.start, width: width)
        let end = x(for: recording.notes.end(of: section, duration: duration) ?? duration, width: width)
        let isCurrent = playback.position >= section.start
            && playback.position < (recording.notes.end(of: section, duration: duration) ?? duration)
        return Button {
            editingSection = section.id
        } label: {
            HStack(spacing: 6) {
                Capsule()
                    .fill(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 2, height: 12)
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(height: Self.laneHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(section.title) · desde \(LibraryFormatting.duration(section.start))")
        .popover(isPresented: Binding(
            get: { editingSection == section.id },
            set: { if !$0 { editingSection = nil } }
        ), arrowEdge: .bottom) {
            SectionEditor(
                section: section,
                onCommit: { title in updateNotes { $0.renameSection(section.id, to: title) } },
                onRemove: { updateNotes { $0.removeSection(section.id) } }
            )
        }
        // The popover points at the name; the name never runs into the next section.
        .frame(maxWidth: max(20, end - start - 6), alignment: .leading)
        .padding(.leading, max(0, start - 1))
    }

    // MARK: Moments

    /// The waveform draws the moment; this makes its dot clickable and describes it.
    private func momentTarget(_ moment: RecordingMoment, width: CGFloat) -> some View {
        Button {
            editingMoment = moment.id
        } label: {
            Color.clear
                .frame(width: 18, height: 18)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("\(moment.title) · \(LibraryFormatting.duration(moment.time))")
        .accessibilityLabel(Text("Momento: \(moment.title), \(LibraryFormatting.duration(moment.time))"))
        .popover(isPresented: Binding(
            get: { editingMoment == moment.id },
            set: { if !$0 { editingMoment = nil } }
        ), arrowEdge: .bottom) {
            MomentEditor(
                moment: moment,
                onCommit: { title, note in updateNotes { $0.editMoment(moment.id, title: title, note: note) } },
                onRemove: { updateNotes { $0.removeMoment(moment.id) } }
            )
        }
        // Placed by layout, not offset, so the popover points at the moment's dot.
        .padding(.leading, max(0, x(for: moment.time, width: width) - 9))
        .padding(.top, Self.laneHeight + 8 - 6)
    }
}
