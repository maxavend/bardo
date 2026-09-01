import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

struct QwenMeetingMinutesGenerator {
    static let modelID = "mlx-community/Qwen3.5-0.8B-MLX-4bit"
    static let engineName = "Qwen 3.5 0.8B (MLX)"

    /// A 0.8B model is fast enough that a few bounded passes are preferable to
    /// keeping a very large KV cache alive for a multi-hour transcript.
    private static let directTranscriptCharacterLimit = 70_000
    private static let chunkCharacterLimit = 30_000

    func generate(
        from transcript: Transcript,
        recordingTitle: String,
        downloadProgress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MeetingMinutes {
        let formattedTranscript = MeetingMinutesTranscriptFormatter
            .formattedLines(from: transcript)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !formattedTranscript.isEmpty else {
            throw MeetingMinutesGenerationError.emptyTranscript
        }

        // Hugging Face's client keeps the downloaded snapshot in its local cache.
        // Keeping the container scoped to this call lets the model be released once
        // the minute has been generated instead of competing with transcription models.
        let configuration = ModelConfiguration(
            id: Self.modelID,
            extraEOSTokens: ["<|im_end|>"]
        )
        let model = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: downloadProgress
        )

        let evidence: String
        if formattedTranscript.count <= Self.directTranscriptCharacterLimit {
            evidence = formattedTranscript
        } else {
            evidence = try await extractEvidence(from: transcript, model: model)
        }

        return try await generateFinalMinutes(
            evidence: evidence,
            transcript: transcript,
            recordingTitle: recordingTitle,
            model: model
        )
    }

    private func extractEvidence(
        from transcript: Transcript,
        model: ModelContainer
    ) async throws -> String {
        let chunks = MeetingMinutesTranscriptFormatter.chunks(
            from: transcript,
            maxCharacters: Self.chunkCharacterLimit
        )

        var digests: [String] = []
        digests.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let session = ChatSession(
                model,
                instructions: Self.evidenceInstructions,
                generateParameters: GenerateParameters(
                    maxTokens: 900,
                    temperature: 0
                ),
                additionalContext: ["enable_thinking": false]
            )

            let digest = try await session.respond(
                to: """
                Fragmento \(index + 1) de \(chunks.count):

                \(chunk)
                """
            )
            let cleaned = digest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                digests.append(cleaned)
            }
        }

        return digests.joined(separator: "\n\n")
    }

    private func generateFinalMinutes(
        evidence: String,
        transcript: Transcript,
        recordingTitle: String,
        model: ModelContainer
    ) async throws -> MeetingMinutes {
        let session = ChatSession(
            model,
            instructions: Self.finalInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 2_000,
                temperature: 0
            ),
            additionalContext: ["enable_thinking": false]
        )

        let response = try await session.respond(
            to: """
            Título de la grabación: \(recordingTitle)
            Idioma detectado: \(transcript.languageCode ?? "desconocido")

            Transcripción o evidencia fiel de la transcripción:
            \(evidence)
            """
        )

        do {
            return try QwenMeetingMinutesResponseParser.parse(
                response,
                recordingID: transcript.recordingID
            )
        } catch {
            // Small local models occasionally wrap or slightly damage JSON. One compact
            // repair pass is cheaper than failing the whole minute and must not add facts.
            let repairSession = ChatSession(
                model,
                instructions: Self.repairInstructions,
                generateParameters: GenerateParameters(
                    maxTokens: 2_000,
                    temperature: 0
                ),
                additionalContext: ["enable_thinking": false]
            )
            let repaired = try await repairSession.respond(to: response)
            return try QwenMeetingMinutesResponseParser.parse(
                repaired,
                recordingID: transcript.recordingID
            )
        }
    }

    private static let evidenceInstructions = """
    Extrae evidencia factual útil para una minuta formal a partir del fragmento de transcripción.
    Sé literal, breve y conservador. Conserva el marcador [t=123s] junto a cada hecho que mantengas.
    Distingue una propuesta de una decisión confirmada. No inventes nombres, responsables, fechas,
    compromisos ni decisiones. Incluye únicamente temas relevantes, decisiones explícitas, tareas,
    compromisos, fechas y preguntas pendientes. Usa el mismo idioma principal de la transcripción.
    Devuelve como máximo 14 viñetas cortas y ningún comentario adicional.
    """

    private static let finalInstructions = """
    Convierte el texto recibido en una minuta formal, clara y concisa. Utiliza únicamente información
    explícitamente presente en la transcripción o evidencia. Una sugerencia no es una decisión a menos
    que el texto indique que fue acordada o confirmada. No infieras responsables ni fechas; usa null
    cuando no estén expresamente indicados. Cada decisión, tarea o pregunta debe usar como sourceSeconds
    el número del marcador [t=123s] más cercano que realmente la respalde, o null si no existe uno fiable.

    Responde ÚNICAMENTE con JSON válido, sin Markdown, explicaciones ni texto antes o después, con esta forma:
    {
      "summary": "resumen ejecutivo breve",
      "topics": ["tema"],
      "decisions": [{"text": "decisión", "sourceSeconds": 123}],
      "actionItems": [{"task": "tarea", "assignee": null, "deadline": null, "sourceSeconds": 123}],
      "openQuestions": [{"text": "pregunta pendiente", "sourceSeconds": 123}]
    }

    Evita duplicar el mismo hecho entre secciones. Mantén el idioma principal de la reunión.
    """

    private static let repairInstructions = """
    Repara únicamente la sintaxis del JSON recibido para que sea JSON válido. No agregues, elimines,
    resumas ni cambies hechos. Conserva exactamente los campos summary, topics, decisions, actionItems
    y openQuestions y sus valores semánticos. Responde solo con el objeto JSON reparado, sin Markdown.
    """
}
