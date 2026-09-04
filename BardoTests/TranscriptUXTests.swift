import Foundation
import XCTest
@testable import Bardo

final class TranscriptUXTests: XCTestCase {
    func testSetupCopyStaysSingleLineAndNonTechnical() {
        let forbiddenTerms = [
            "whisper", "speakerkit", "core ml", "model", "transcription",
            "diarization", "pyannote", "tokenizer"
        ]

        for copy in TranscriptionSetupCopy.allVisibleCopy {
            XCTAssertFalse(copy.contains("\n"), "Unexpected line break in: \(copy)")
            XCTAssertFalse(copy.contains("\r"), "Unexpected carriage return in: \(copy)")
            XCTAssertFalse(copy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let normalized = copy.lowercased()
            for term in forbiddenTerms {
                XCTAssertFalse(normalized.contains(term), "Technical term '\(term)' in: \(copy)")
            }
        }
    }

    func testSetupCopyUsesPlainSpanishForTheFirstRun() {
        XCTAssertEqual(TranscriptionSetupCopy.title(for: .listening), "Preparando Bardo")
        XCTAssertEqual(
            TranscriptionSetupCopy.detail(for: .listening),
            "Estamos preparando todo para que puedas empezar."
        )
        XCTAssertEqual(TranscriptionSetupCopy.stageLabel(for: .listening), "Preparando el reconocimiento de voz…")
        XCTAssertEqual(TranscriptionSetupCopy.cancelButton, "Pausar")
        XCTAssertEqual(TranscriptionSetupCopy.footer, "Esto solo ocurre una vez. Después, Bardo estará listo para ti.")
    }

    func testEachSetupStageHasRotatingMessages() {
        for stage in TranscriptionSetupCopy.Stage.allCases {
            XCTAssertGreaterThanOrEqual(
                TranscriptionSetupCopy.messages(for: stage).count,
                3,
                "Stage \(stage) should have enough messages to feel alive"
            )
        }
    }

    func testFirstRunProgressCopyCoversEveryPreparationPhase() {
        XCTAssertEqual(TranscriptionSetupCopy.stageLabel(for: .listening), "Preparando el reconocimiento de voz…")
        XCTAssertEqual(TranscriptionSetupCopy.stageLabel(for: .preparingMinutes), "Preparando minutas…")
        XCTAssertEqual(TranscriptionSetupCopy.stageLabel(for: .welcomingVoices), "Organizando las voces…")

        for stage in [
            TranscriptionSetupCopy.Stage.listening,
            .preparingMinutes,
            .welcomingVoices
        ] {
            XCTAssertGreaterThanOrEqual(TranscriptionSetupCopy.messages(for: stage).count, 3)
        }
    }

    func testManualChangeFlagsDistinguishTextAndSpeakerNames() {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000700")!
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000799")!
        let metadata = TranscriptMetadata(
            engine: "WhisperKit",
            engineVersion: "1.0.0",
            modelID: "test-model"
        )

        let untouched = Transcript(
            recordingID: recordingID,
            speakers: [Speaker(id: speakerID)],
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Original")],
            metadata: metadata
        )
        XCTAssertFalse(untouched.hasManualTextEdits)
        XCTAssertFalse(untouched.hasNamedSpeakers)
        XCTAssertFalse(untouched.hasManualChanges)

        let textEdited = Transcript(
            recordingID: recordingID,
            speakers: [Speaker(id: speakerID)],
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Original",
                    editedText: "Corrected"
                )
            ],
            metadata: metadata
        )
        XCTAssertTrue(textEdited.hasManualTextEdits)
        XCTAssertFalse(textEdited.hasNamedSpeakers)
        XCTAssertTrue(textEdited.hasManualChanges)

        let named = Transcript(
            recordingID: recordingID,
            speakers: [Speaker(id: speakerID, name: "  Maxi  ")],
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Original")],
            metadata: metadata
        )
        XCTAssertFalse(named.hasManualTextEdits)
        XCTAssertTrue(named.hasNamedSpeakers)
        XCTAssertTrue(named.hasManualChanges)
    }

    func testTranscriptSegmentDecodesWithoutEditedTextAndUsesOriginalText() throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let transcript = Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startTime: 1,
                    endTime: 3,
                    text: "Original transcript"
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "test-model",
                createdAt: Date(timeIntervalSince1970: 1_700_007_001)
            )
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(TranscriptDocumentV1(transcript: transcript))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var transcriptJSON = try XCTUnwrap(document["transcript"] as? [String: Any])
        var segmentsJSON = try XCTUnwrap(transcriptJSON["segments"] as? [[String: Any]])
        segmentsJSON[0].removeValue(forKey: "editedText")
        transcriptJSON["segments"] = segmentsJSON
        document["transcript"] = transcriptJSON

        let legacyData = try JSONSerialization.data(withJSONObject: document)
        let decoded = try JSONDecoder().decode(TranscriptDocumentV1.self, from: legacyData).transcript

        XCTAssertEqual(decoded.segments.first?.text, "Original transcript")
        XCTAssertNil(decoded.segments.first?.editedText)
        XCTAssertEqual(decoded.segments.first?.displayText, "Original transcript")
        XCTAssertEqual(decoded.text, "Original transcript")
    }

    func testEditedTextRoundTripPreservesOriginalWordsAndTimingEvidence() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = makeRecording(id: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!)
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let word = TranscriptWord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!,
            startTime: 4,
            endTime: 4.5,
            text: "teh",
            probability: 0.8
        )
        let originalSegment = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!,
            startTime: 4,
            endTime: 6,
            text: "teh original",
            words: [word],
            editedText: "the original"
        )
        let transcript = makeTranscript(recordingID: recording.id, segments: [originalSegment])

        let transcriptStore = TranscriptStore(rootURL: rootURL)
        try await transcriptStore.save(transcript)
        let reloadedValue = try await transcriptStore.read(recordingID: recording.id)
        let reloaded = try XCTUnwrap(reloadedValue)

        XCTAssertEqual(reloaded.segments[0].text, "teh original")
        XCTAssertEqual(reloaded.segments[0].editedText, "the original")
        XCTAssertEqual(reloaded.segments[0].displayText, "the original")
        XCTAssertEqual(reloaded.segments[0].words, [word])
        XCTAssertEqual(reloaded.segments[0].startTime, 4)
        XCTAssertEqual(reloaded.segments[0].endTime, 6)
        XCTAssertEqual(reloaded.text, "the original")
    }

    @MainActor
    func testSpeakerRenameAndSegmentEditPersistAcrossFreshViewModel() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000706")!
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000708")!
        let recording = makeRecording(id: recordingID)
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let transcript = Transcript(
            recordingID: recordingID,
            languageCode: "es",
            speakers: [Speaker(id: speakerID)],
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startTime: 10,
                    endTime: 14,
                    speakerID: speakerID,
                    text: "ola mundo",
                    words: [
                        TranscriptWord(startTime: 10, endTime: 10.4, text: "ola"),
                        TranscriptWord(startTime: 10.5, endTime: 11, text: "mundo")
                    ]
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "test-model"
            ),
            diarizationMetadata: DiarizationMetadata(
                engine: "SpeakerKit",
                engineVersion: "1.0.0",
                modelID: "test-speakers"
            )
        )
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        try await transcriptStore.save(transcript)

        let model = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL)
        )
        await model.reload()

        await model.renameSpeaker(speakerID, to: "  Maxi  ")
        await model.updateTranscriptSegment(segmentID, text: "  Hola mundo  ")

        XCTAssertEqual(model.transcript?.speakers.first?.name, "Maxi")
        XCTAssertEqual(model.transcript?.segments.first?.text, "ola mundo")
        XCTAssertEqual(model.transcript?.segments.first?.editedText, "Hola mundo")
        XCTAssertEqual(model.transcript?.segments.first?.words.count, 2)
        XCTAssertNil(model.transcriptEditErrorMessage)

        let restarted = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL)
        )
        await restarted.reload()

        XCTAssertEqual(restarted.transcript?.speakers.first?.name, "Maxi")
        XCTAssertEqual(restarted.transcript?.segments.first?.text, "ola mundo")
        XCTAssertEqual(restarted.transcript?.segments.first?.displayText, "Hola mundo")
        XCTAssertEqual(restarted.transcript?.segments.first?.words.count, 2)
    }

    @MainActor
    func testRestoringSegmentAndClearingSpeakerNameReturnsAutomaticState() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000709")!
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000710")!
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
        let recording = makeRecording(id: recordingID)
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let transcript = Transcript(
            recordingID: recordingID,
            speakers: [Speaker(id: speakerID, name: "Alice")],
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startTime: 0,
                    endTime: 2,
                    speakerID: speakerID,
                    text: "raw words",
                    editedText: "Correct words"
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "test-model"
            )
        )
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        try await transcriptStore.save(transcript)

        let model = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL)
        )
        await model.reload()
        await model.restoreOriginalTranscriptSegment(segmentID)
        await model.renameSpeaker(speakerID, to: "   ")

        let persistedStore = TranscriptStore(rootURL: rootURL)
        let persistedValue = try await persistedStore.read(recordingID: recordingID)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertNil(persisted.segments.first?.editedText)
        XCTAssertEqual(persisted.segments.first?.displayText, "raw words")
        XCTAssertNil(persisted.speakers.first?.name)
    }

    @MainActor
    func testEmptySegmentEditIsRejectedWithoutChangingPersistedTranscript() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000712")!
        let segmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000713")!
        let recording = makeRecording(id: recordingID)
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let transcript = makeTranscript(
            recordingID: recordingID,
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startTime: 0,
                    endTime: 1,
                    text: "Keep me"
                )
            ]
        )
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        try await transcriptStore.save(transcript)

        let model = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL)
        )
        await model.reload()
        await model.updateTranscriptSegment(segmentID, text: "   \n  ")

        XCTAssertEqual(model.transcriptEditErrorMessage, "Transcript text cannot be empty.")
        XCTAssertEqual(model.transcript?.segments.first?.displayText, "Keep me")

        let persistedValue = try await transcriptStore.read(recordingID: recordingID)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertNil(persisted.segments.first?.editedText)
        XCTAssertEqual(persisted.segments.first?.displayText, "Keep me")
    }

    private func makeRecording(id: Recording.ID) -> Recording {
        Recording(
            id: id,
            title: "Transcript UX fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_007_000),
            duration: 30,
            sources: [.importedFile],
            processingState: .completed,
            audioAssets: []
        )
    }

    private func makeTranscript(
        recordingID: Recording.ID,
        segments: [TranscriptSegment]
    ) -> Transcript {
        Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "test-model",
                createdAt: Date(timeIntervalSince1970: 1_700_007_002)
            )
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoTranscriptUXTests-\(UUID().uuidString)", isDirectory: true)
    }
}
