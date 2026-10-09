import Foundation
import XCTest
@testable import Bardo

@MainActor
final class LibraryPresentationTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15, minute: 30))!
    }

    // MARK: - List dates

    func testListDateShowsTheTimeForToday() {
        let morning = calendar.date(byAdding: .hour, value: -4, to: now)!
        XCTAssertEqual(
            LibraryFormatting.listDate(morning, now: now, calendar: calendar),
            morning.formatted(date: .omitted, time: .shortened)
        )
    }

    func testListDateSaysYesterday() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LibraryFormatting.listDate(yesterday, now: now, calendar: calendar), String(localized: "Yesterday"))
    }

    func testListDateShowsTheWeekdayWithinAWeek() {
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(
            LibraryFormatting.listDate(threeDaysAgo, now: now, calendar: calendar),
            threeDaysAgo.formatted(.dateTime.weekday(.wide)).localizedCapitalized
        )
    }

    func testListDateOmitsTheYearOnlyForThisYear() {
        let september = calendar.date(byAdding: .day, value: -9, to: now)!
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        XCTAssertEqual(
            LibraryFormatting.listDate(september, now: now, calendar: calendar),
            september.formatted(.dateTime.day().month(.abbreviated))
        )
        XCTAssertEqual(
            LibraryFormatting.listDate(lastYear, now: now, calendar: calendar),
            lastYear.formatted(.dateTime.day().month(.abbreviated).year())
        )
    }

    // MARK: - Search

    func testSearchIgnoresAccentsAndCase() throws {
        let document = makeDocument(transcript: "Revisamos el diseño de la biblioteca.")
        let match = try XCTUnwrap(document.match(query: "DISENO"))
        XCTAssertEqual(match.kind, .transcript)
        XCTAssertTrue(LibraryFormatting.containsSearchTerms("Diseño", query: "diseno"))
    }

    func testSearchRequiresEveryTerm() {
        let document = makeDocument(transcript: "Revisamos el diseño de la biblioteca.")
        XCTAssertNotNil(document.match(query: "diseño biblioteca"))
        XCTAssertNil(document.match(query: "diseño presupuesto"))
    }

    func testParticipantMatchesComeFirst() throws {
        let document = makeDocument(participants: ["Mónica"], transcript: "Mónica presentó el diseño.")
        let match = try XCTUnwrap(document.match(query: "monica"))
        XCTAssertEqual(match.kind, .participant)
    }

    func testTitleOnlyMatchesAreMarkedAsTitle() throws {
        let document = makeDocument(title: "Planificación del sprint", transcript: "Hablamos de fechas.")
        XCTAssertEqual(try XCTUnwrap(document.match(query: "sprint")).kind, .title)
    }

    func testSnippetsStartAndEndOnWholeWords() throws {
        let filler = String(repeating: "palabra ", count: 30)
        let document = makeDocument(transcript: filler + "entonces mañana cerramos el sprint con el equipo " + filler)
        let snippet = try XCTUnwrap(document.match(query: "sprint")).context
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        let words = snippet.trimmingCharacters(in: CharacterSet(charactersIn: "…")).split(separator: " ")
        let vocabulary: Set<Substring> = ["palabra", "entonces", "mañana", "cerramos", "el", "sprint", "con", "equipo"]
        XCTAssertTrue(words.allSatisfy(vocabulary.contains), "Cut a word in half: \(snippet)")
        XCTAssertTrue(snippet.contains("sprint"))
    }

    func testHighlightMarksEveryOccurrence() {
        let text = LibraryFormatting.highlighted("Diseño y más diseño", matching: "diseno", style: .emphasis)
        let marked = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(marked.count, 2)
    }

    // MARK: - Sections and sorting

    func testSectionsFilterBySourceAndFavorite() {
        let suite = "LibraryPresentationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = BardoFavoritesStore(defaults: defaults)
        let recorded = Recording(title: "Grabada", sources: [.microphone])
        let imported = Recording(title: "Importada", sources: [.importedFile])
        favorites.toggle(imported.id)

        XCTAssertTrue(BardoLibrarySection.all.contains(recorded, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.recorded.contains(recorded, favorites: favorites))
        XCTAssertFalse(BardoLibrarySection.recorded.contains(imported, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.imported.contains(imported, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.favorites.contains(imported, favorites: favorites))
        XCTAssertFalse(BardoLibrarySection.favorites.contains(recorded, favorites: favorites))
    }

    func testSortOrders() {
        let old = Recording(title: "Beta", createdAt: now.addingTimeInterval(-86_400), duration: 300, sources: [.microphone])
        let new = Recording(title: "alfa", createdAt: now, duration: 60, sources: [.microphone])
        XCTAssertEqual(BardoLibrarySort.newest.sorted([old, new]).map(\.id), [new.id, old.id])
        XCTAssertEqual(BardoLibrarySort.oldest.sorted([new, old]).map(\.id), [old.id, new.id])
        XCTAssertEqual(BardoLibrarySort.name.sorted([old, new]).map(\.id), [new.id, old.id])
        XCTAssertEqual(BardoLibrarySort.duration.sorted([new, old]).map(\.id), [old.id, new.id])
    }

    private func makeDocument(
        title: String = "Reunión",
        participants: [String] = [],
        transcript: String
    ) -> LibrarySearchDocument {
        LibrarySearchDocument(
            id: UUID(),
            title: title,
            createdAt: now,
            duration: 60,
            source: "Micrófono",
            participantNames: participants,
            namedParticipants: participants,
            transcriptText: transcript
        )
    }
}
