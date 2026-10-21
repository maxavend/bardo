import XCTest
@testable import Bardo

final class RecordingNotesTests: XCTestCase {
    func testMomentsAndSectionsStayInTimeOrderWithReadableDefaults() {
        var notes = RecordingNotes()
        notes.addMoment(at: 90, title: "  ", note: "  ")
        notes.addMoment(at: 30, title: "Decisión", note: "Lanzar el jueves")
        notes.addSection(at: 60, title: "")
        notes.addSection(at: 0, title: "Contexto")

        XCTAssertEqual(notes.moments.map(\.time), [30, 90])
        XCTAssertEqual(notes.moments[1].title, RecordingMoment.defaultTitle(at: 90), "A blank moment is titled after its time")
        XCTAssertNil(notes.moments[1].note)
        XCTAssertEqual(notes.sections.map(\.title), ["Contexto", String(localized: "Section 1")])
        XCTAssertEqual(notes.end(of: notes.sections[0], duration: 120), 60, "A section ends where the next starts")
        XCTAssertEqual(notes.end(of: notes.sections[1], duration: 120), 120)
    }

    func testEditingKeepsTheTimeAndBlankTitlesFallBack() {
        var notes = RecordingNotes()
        let moment = notes.addMoment(at: 12, title: "Primero", note: nil)
        notes.editMoment(moment.id, title: "", note: "Detalle")

        XCTAssertEqual(notes.moments.first?.time, 12)
        XCTAssertEqual(notes.moments.first?.title, RecordingMoment.defaultTitle(at: 12))
        XCTAssertEqual(notes.moments.first?.note, "Detalle")

        notes.removeMoment(moment.id)
        XCTAssertTrue(notes.isEmpty)
    }

    func testNotesSitAmongParagraphsWhereTheyHappened() {
        var notes = RecordingNotes()
        notes.addSection(at: 39.5, title: "Propuesta")
        notes.addSection(at: 500, title: "Cierre")
        notes.addMoment(at: 2, title: "Antes de hablar", note: nil)
        notes.addMoment(at: 24, title: "Durante", note: nil)

        let placement = TranscriptNotePlacement(notes: notes, paragraphStarts: [5, 18, 40, 58])

        XCTAssertEqual(placement.leadingMoments.map(\.title), ["Antes de hablar"], "A moment before anyone speaks comes first")
        XCTAssertEqual(placement.sections(before: 2).map(\.title), ["Propuesta"], "A section heads the paragraph it starts")
        XCTAssertEqual(placement.moments(after: 1).map(\.title), ["Durante"], "A moment follows the paragraph it was marked in")
        XCTAssertEqual(placement.trailingSections.map(\.title), ["Cierre"])
    }

    func testCopiedTextIncludesSectionsAndMoments() {
        var notes = RecordingNotes()
        notes.addSection(at: 0, title: "Planificación")
        notes.addMoment(at: 20, title: "Fecha", note: "Definir con Diego")
        let valentina = Speaker(name: "Valentina")
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: [valentina],
            segments: [TranscriptSegment(startTime: 0, endTime: 72, speakerID: valentina.id, text: "Partamos.")],
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "test")
        )

        let text = TranscriptTextFormatter(title: "Revisión", notes: notes, localName: nil).text(for: transcript)

        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "Revisión",
            "",
            "PLANIFICACIÓN · 0:00",
            "",
            "Valentina (0:00–1:12)",
            "Partamos.",
            "⚑ 0:20 · Fecha: Definir con Diego"
        ])
    }
}
