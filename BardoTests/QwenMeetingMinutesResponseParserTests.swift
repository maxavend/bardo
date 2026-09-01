import XCTest
@testable import Bardo

final class QwenMeetingMinutesResponseParserTests: XCTestCase {
    func testParsesFencedStructuredMinutesAndPreservesSourceTimes() throws {
        let recordingID = UUID()
        let response = """
        ```json
        {
          "summary": "Se acordó preparar y revisar el prototipo.",
          "topics": ["Prototipo", "Entrega"],
          "decisions": [
            {"text": "El prototipo se revisará el viernes.", "sourceSeconds": 754}
          ],
          "actionItems": [
            {"task": "Preparar las pantallas", "assignee": "Ana", "deadline": null, "sourceSeconds": 812}
          ],
          "openQuestions": [
            {"text": "Falta confirmar la hora de revisión.", "sourceSeconds": null}
          ]
        }
        ```
        """

        let minutes = try QwenMeetingMinutesResponseParser.parse(
            response,
            recordingID: recordingID
        )

        XCTAssertEqual(minutes.recordingID, recordingID)
        XCTAssertEqual(minutes.summary, "Se acordó preparar y revisar el prototipo.")
        XCTAssertEqual(minutes.topics, ["Prototipo", "Entrega"])
        XCTAssertEqual(minutes.decisions.first?.sourceTime, 754)
        XCTAssertEqual(minutes.actionItems.first?.task, "Preparar las pantallas")
        XCTAssertEqual(minutes.actionItems.first?.assignee, "Ana")
        XCTAssertNil(minutes.actionItems.first?.deadline)
        XCTAssertEqual(minutes.actionItems.first?.sourceTime, 812)
        XCTAssertNil(minutes.openQuestions.first?.sourceTime)
        XCTAssertEqual(minutes.engine, QwenMeetingMinutesGenerator.engineName)
    }

    func testRejectsResponseWithoutJSONObject() {
        XCTAssertThrowsError(
            try QwenMeetingMinutesResponseParser.parse(
                "No pude generar la minuta.",
                recordingID: UUID()
            )
        )
    }
}
