import Foundation
import XCTest
@testable import Bardo

final class MeetingMinutesGeneratorTests: XCTestCase {
    func testInputContainsOnlyTranscriptTitleAndContextEvenWhenRecordingHasAudioAssets() throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        let recording = Recording(
            id: recordingID,
            title: "Audio source that must never reach Qwen",
            sources: [.importedFile],
            audioAssets: [
                AudioAsset(
                    originalFileName: "private-audio.wav",
                    fileExtension: "wav",
                    metadata: AudioMetadata(
                        duration: 12,
                        codec: "pcm",
                        sampleRate: 16_000,
                        channelCount: 1
                    )
                )
            ]
        )
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: recording.id, text: "Discuss launch."),
            title: recording.title,
            context: "Planning"
        )

        let labels = Mirror(reflecting: input).children.compactMap(\.label)
        XCTAssertEqual(labels, ["transcript", "title", "context"])
        XCTAssertFalse(String(describing: input).contains("private-audio.wav"))
        XCTAssertFalse(String(describing: input).contains("URL"))
        XCTAssertFalse(String(describing: input).contains("[Float]"))
    }

    func testGeneratorUsesDeterministicConservativeTextOnlyPrompt() async throws {
        let spy = TextGeneratorSpy(responses: ["## Summary\n- Launch was discussed."])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_602)
        let generator = QwenMeetingMinutesGenerator(
            textGenerator: spy,
            dateProvider: { createdAt }
        )
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: UUID(), text: "Maxi asked whether we should launch."),
            title: "Product planning",
            context: "Weekly meeting"
        )

        let result = try await generator.generate(from: input, progress: { _ in })
        let prompts = await spy.prompts

        XCTAssertEqual(result.modelID, QwenMeetingMinutesModel.modelID)
        XCTAssertEqual(result.text, "## Summary\n- Launch was discussed.")
        XCTAssertEqual(result.createdAt, createdAt)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("Product planning"))
        XCTAssertTrue(prompts[0].contains("Weekly meeting"))
        XCTAssertTrue(prompts[0].contains("Maxi asked whether we should launch."))
        XCTAssertTrue(prompts[0].contains("Do not invent names, deadlines, decisions, or agreements."))
        XCTAssertTrue(prompts[0].contains("A question is not an agreement."))
        XCTAssertFalse(prompts[0].contains("private-audio.wav"))
        XCTAssertFalse(prompts[0].contains("samples"))
        let options = await spy.options
        XCTAssertEqual(options.first?.temperature, 0)
    }

    func testLongTranscriptUsesSegmentBoundedExtractionThenFinalSynthesis() async throws {
        let spy = TextGeneratorSpy(responses: ["Extract one", "Extract two", "Final minutes"])
        let generator = QwenMeetingMinutesGenerator(
            textGenerator: spy,
            chunkCharacterLimit: 80,
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_603) }
        )
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: [Speaker(name: "Maxi")],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, speakerID: nil, text: String(repeating: "first ", count: 20)),
                TranscriptSegment(startTime: 2, endTime: 3, speakerID: nil, text: String(repeating: "second ", count: 20))
            ],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "test", modelID: "test")
        )

        let result = try await generator.generate(
            from: MeetingMinutesInput(transcript: transcript, title: "Long meeting", context: nil),
            progress: { _ in }
        )
        let prompts = await spy.prompts

        XCTAssertEqual(result.text, "Final minutes")
        XCTAssertEqual(prompts.count, 3)
        XCTAssertTrue(prompts[0].contains("Extract only supported facts"))
        XCTAssertTrue(prompts[1].contains("Extract only supported facts"))
        XCTAssertTrue(prompts[2].contains("Extract one"))
        XCTAssertTrue(prompts[2].contains("Extract two"))
    }

    private func makeTranscript(recordingID: Recording.ID, text: String) -> Transcript {
        Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: text)],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "test",
                modelID: "large-v3-v20240930_turbo_632MB"
            )
        )
    }
}

private actor TextGeneratorSpy: MeetingMinutesTextGenerating {
    struct Call: Sendable {
        let prompt: String
        let options: MeetingMinutesGenerationOptions
    }

    private let responses: [String]
    private var index = 0
    private(set) var calls: [Call] = []

    init(responses: [String]) {
        self.responses = responses
    }

    var prompts: [String] {
        calls.map(\.prompt)
    }

    var options: [MeetingMinutesGenerationOptions] {
        calls.map(\.options)
    }

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        calls.append(Call(prompt: prompt, options: options))
        progress(1)
        defer { index += 1 }
        return responses[min(index, responses.count - 1)]
    }
}
