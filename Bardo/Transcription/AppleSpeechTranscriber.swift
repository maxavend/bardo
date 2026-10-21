import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's speech recognition, built into macOS 26 and later. It listens in the
/// language of the Mac, keeps its models in macOS rather than in Bardo, and reports a
/// time for every word, so playback and speaker identification work as with Whisper.
@available(macOS 26.0, *)
enum AppleSpeechTranscriber {
    enum Failure: Error, LocalizedError {
        case unsupportedLanguage

        var errorDescription: String? {
            "El reconocimiento de Apple no está disponible en el idioma de este Mac."
        }
    }

    /// The Mac's language as Apple's recognition knows it.
    static func locale() async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw Failure.unsupportedLanguage
        }
        return locale
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// Whether macOS already has what it needs for the Mac's language.
    static func isReady() async -> Bool {
        guard let locale = try? await locale() else { return false }
        return await AssetInventory.status(forModules: [transcriber(for: locale)]) == .installed
    }

    /// Asks macOS to download what it needs for the Mac's language, if anything.
    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let module = transcriber(for: try await locale())
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            progress(1)
            return
        }
        let observation = request.progress.observe(\.fractionCompleted) { reported, _ in
            progress(reported.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// Transcribes one track, placing its passages and words on the recording's timeline.
    static func transcribe(
        _ pass: TranscriptionPass,
        onSegment: @escaping @Sendable ([TranscriptSegment]) -> Void
    ) async throws -> [TranscriptSegment] {
        let locale = try await locale()
        try await prepare(progress: { _ in })
        let module = transcriber(for: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: pass.url)

        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in module.results {
                let sentences = Self.sentences(from: result, in: pass)
                guard !sentences.isEmpty else { continue }
                segments += sentences
                onSegment(sentences)
            }
            return segments
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Apple reports long stretches of speech at once; they are split into sentences at
    /// their punctuation, using each word's time, so passages read and play like Whisper's.
    static func sentences(from result: SpeechTranscriber.Result, in pass: TranscriptionPass) -> [TranscriptSegment] {
        var sentences: [TranscriptSegment] = []
        var text = ""
        var words: [TranscriptWord] = []

        func flush() {
            let clean = TranscriptTextSanitizer.normalizeRecognizedText(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, let first = words.first, let last = words.last {
                sentences.append(TranscriptSegment(
                    startTime: first.startTime,
                    endTime: last.endTime,
                    text: clean,
                    words: words,
                    source: pass.source
                ))
            }
            text = ""
            words = []
        }

        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            text += piece
            if let range = run.audioTimeRange {
                let word = piece.trimmingCharacters(in: .whitespaces)
                if !word.isEmpty {
                    words.append(TranscriptWord(
                        startTime: range.start.seconds + pass.offset,
                        endTime: range.end.seconds + pass.offset,
                        text: word,
                        probability: nil
                    ))
                }
            }
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let endsSentence = trimmed.last.map { ".?!…".contains($0) } ?? false
            if (endsSentence && words.count >= 3) || words.count >= 40 {
                flush()
            }
        }
        flush()

        // Without word times, the result is kept whole.
        if sentences.isEmpty {
            let clean = TranscriptTextSanitizer.normalizeRecognizedText(String(result.text.characters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return [] }
            return [TranscriptSegment(
                startTime: result.range.start.seconds + pass.offset,
                endTime: result.range.end.seconds + pass.offset,
                text: clean,
                source: pass.source
            )]
        }
        return sentences
    }
}
