import Foundation

/// A point in a recording someone marked while it ran or afterwards: a title and,
/// optionally, a note, like jotting something down during a meeting.
struct RecordingMoment: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var time: TimeInterval
    var title: String
    var note: String?

    init(id: UUID = UUID(), time: TimeInterval, title: String, note: String? = nil) {
        self.id = id
        self.time = max(0, time)
        self.title = title
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// The title a moment gets when the person types none, such as "Momento 12:31".
    static func defaultTitle(at time: TimeInterval) -> String {
        String(localized: "Moment \(LibraryFormatting.duration(time))")
    }
}

/// A named part of a recording, from its start until the next section begins. The
/// audio stays one file; sections only name stretches of it.
struct RecordingSection: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var start: TimeInterval
    var title: String

    init(id: UUID = UUID(), start: TimeInterval, title: String) {
        self.id = id
        self.start = max(0, start)
        self.title = title
    }
}

/// The moments and sections of one recording, kept in time order.
struct RecordingNotes: Codable, Equatable, Hashable, Sendable {
    private(set) var moments: [RecordingMoment] = []
    private(set) var sections: [RecordingSection] = []

    init(moments: [RecordingMoment] = [], sections: [RecordingSection] = []) {
        self.moments = moments.sorted { $0.time < $1.time }
        self.sections = sections.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { moments.isEmpty && sections.isEmpty }

    /// Adds a moment, titled after its time when `title` is blank.
    @discardableResult
    mutating func addMoment(at time: TimeInterval, title: String, note: String?) -> RecordingMoment {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? RecordingMoment.defaultTitle(at: time)
        let moment = RecordingMoment(time: time, title: title, note: note)
        moments.append(moment)
        moments.sort { $0.time < $1.time }
        return moment
    }

    /// Starts a section at `time`; the one before it ends there.
    @discardableResult
    mutating func addSection(at time: TimeInterval, title: String) -> RecordingSection {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? nextSectionTitle
        let section = RecordingSection(start: time, title: title)
        sections.append(section)
        sections.sort { $0.start < $1.start }
        return section
    }

    /// Retitles a moment and sets its note; a blank title goes back to the default one.
    mutating func editMoment(_ id: RecordingMoment.ID, title: String, note: String?) {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        let time = moments[index].time
        moments[index] = RecordingMoment(
            id: id,
            time: time,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? RecordingMoment.defaultTitle(at: time),
            note: note
        )
    }

    mutating func renameSection(_ id: RecordingSection.ID, to title: String) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return }
        sections[index].title = title
    }

    mutating func update(_ moment: RecordingMoment) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index] = moment
        moments.sort { $0.time < $1.time }
    }

    mutating func update(_ section: RecordingSection) {
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[index] = section
        sections.sort { $0.start < $1.start }
    }

    mutating func removeMoment(_ id: RecordingMoment.ID) {
        moments.removeAll { $0.id == id }
    }

    mutating func removeSection(_ id: RecordingSection.ID) {
        sections.removeAll { $0.id == id }
    }

    /// "Sección 2" after the first, so a quick Enter still names each part.
    var nextSectionTitle: String {
        String(localized: "Section \(sections.count + 1)")
    }

    /// Where a section ends: where the next one starts, or the end of the recording.
    func end(of section: RecordingSection, duration: TimeInterval?) -> TimeInterval? {
        sections.first { $0.start > section.start }?.start ?? duration
    }
}

/// Where moments and sections go among the blocks of a transcript: a section heads the
/// first block it covers, and a moment follows the block during which it was marked.
struct TranscriptNotePlacement {
    /// A section that starts this close before a paragraph still heads it.
    static let tolerance: TimeInterval = 1

    private var sectionsByParagraph: [Int: [RecordingSection]] = [:]
    private var momentsByParagraph: [Int: [RecordingMoment]] = [:]
    private(set) var leadingMoments: [RecordingMoment] = []
    private(set) var trailingSections: [RecordingSection] = []

    init(notes: RecordingNotes, paragraphStarts: [TimeInterval]) {
        for section in notes.sections {
            if let index = paragraphStarts.firstIndex(where: { $0 >= section.start - Self.tolerance }) {
                sectionsByParagraph[index, default: []].append(section)
            } else {
                trailingSections.append(section)
            }
        }
        for moment in notes.moments {
            if let index = paragraphStarts.lastIndex(where: { $0 <= moment.time }) {
                momentsByParagraph[index, default: []].append(moment)
            } else {
                leadingMoments.append(moment)
            }
        }
    }

    func sections(before paragraph: Int) -> [RecordingSection] { sectionsByParagraph[paragraph] ?? [] }
    func moments(after paragraph: Int) -> [RecordingMoment] { momentsByParagraph[paragraph] ?? [] }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
