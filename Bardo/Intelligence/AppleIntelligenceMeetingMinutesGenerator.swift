import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligenceMeetingMinutesGenerator {
    static let engineName = "Apple Intelligence"

    func availability() -> MeetingMinutesAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            }
        }
        #endif

        return .requiresNewerMacOS
    }

    func generate(from transcript: Transcript, recordingTitle: String) async throws -> MeetingMinutes {
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingMinutesGenerationError.emptyTranscript
        }

        let currentAvailability = availability()
        guard currentAvailability == .available else {
            throw MeetingMinutesGenerationError.unavailable(currentAvailability)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generateWithFoundationModels(
                from: transcript,
                recordingTitle: recordingTitle
            )
        }
        #endif

        throw MeetingMinutesGenerationError.unavailable(.requiresNewerMacOS)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private extension AppleIntelligenceMeetingMinutesGenerator {
    func generateWithFoundationModels(
        from transcript: Transcript,
        recordingTitle: String
    ) async throws -> MeetingMinutes {
        let chunks = MeetingMinutesTranscriptFormatter.chunks(from: transcript)
        guard !chunks.isEmpty else {
            throw MeetingMinutesGenerationError.emptyTranscript
        }

        var digests: [String] = []
        digests.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession(instructions: Self.chunkInstructions)
            let response = try await session.respond(
                to: """
                Transcript chunk \(index + 1) of \(chunks.count):
                \(chunk)
                """
            )
            digests.append(response.content)
        }

        let consolidatedEvidence = try await consolidateDigests(digests)
        let languageHint = transcript.languageCode ?? "unknown"
        let session = LanguageModelSession(instructions: Self.finalInstructions)
        let response = try await session.respond(
            to: """
            Recording title: \(recordingTitle)
            Transcript language: \(languageHint)

            Evidence extracted from the transcript:
            \(consolidatedEvidence)
            """,
            generating: GeneratedMeetingMinutes.self
        )

        return response.content.domainValue(recordingID: transcript.recordingID)
    }

    func consolidateDigests(_ digests: [String]) async throws -> String {
        var current = digests.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !current.isEmpty else { return "" }

        let targetCharacterLimit = 9_000
        var pass = 0

        while current.joined(separator: "\n").count > targetCharacterLimit, pass < 4 {
            var next: [String] = []
            var group: [String] = []
            var groupCount = 0

            for digest in current {
                let additional = digest.count + (group.isEmpty ? 0 : 1)
                if !group.isEmpty, groupCount + additional > targetCharacterLimit {
                    next.append(try await condenseEvidence(group.joined(separator: "\n")))
                    group = []
                    groupCount = 0
                }

                group.append(digest)
                groupCount += additional
            }

            if !group.isEmpty {
                next.append(try await condenseEvidence(group.joined(separator: "\n")))
            }

            current = next
            pass += 1
        }

        let combined = current.joined(separator: "\n")
        if combined.count <= targetCharacterLimit {
            return combined
        }

        return String(combined.prefix(targetCharacterLimit))
    }

    func condenseEvidence(_ evidence: String) async throws -> String {
        let session = LanguageModelSession(instructions: Self.condenseInstructions)
        let response = try await session.respond(to: evidence)
        return response.content
    }

    static var chunkInstructions: String {
        """
        Extract factual meeting evidence from this transcript chunk. Be concise and literal.
        Preserve the exact [t=123s] source marker for every decision, action item, commitment, deadline, unresolved question, or important topic you keep.
        Distinguish proposals from confirmed decisions. Never invent a person, deadline, decision, or commitment.
        Keep at most 10 short bullet points. Write in the same primary language as the transcript.
        """
    }

    static var condenseInstructions: String {
        """
        Consolidate these meeting-evidence bullets without adding information.
        Remove duplicates, keep confirmed decisions separate from proposals, and preserve the original [t=123s] marker beside every factual item.
        Keep the result compact enough for a final meeting-minutes pass and use the same language as the evidence.
        """
    }

    static var finalInstructions: String {
        """
        Create formal, concise meeting minutes only from the supplied evidence.
        Do not infer facts that are not explicitly supported. A suggestion is not a decision unless the evidence says it was agreed or confirmed.
        For action items, leave assignee or deadline nil when not explicitly stated.
        Copy sourceSeconds from the nearest [t=123s] marker. Use nil when no reliable source marker exists.
        Keep the summary short, topics useful, and avoid duplicating the same fact across sections.
        Write in the same primary language as the transcript evidence.
        """
    }
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedMeetingMinutes {
    var summary: String
    var topics: [String]
    var decisions: [GeneratedMinutesItem]
    var actionItems: [GeneratedActionItem]
    var openQuestions: [GeneratedMinutesItem]

    func domainValue(recordingID: Recording.ID) -> MeetingMinutes {
        MeetingMinutes(
            recordingID: recordingID,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            topics: topics.cleanedStrings,
            decisions: decisions.compactMap(\.domainValue),
            actionItems: actionItems.compactMap(\.domainValue),
            openQuestions: openQuestions.compactMap(\.domainValue),
            engine: AppleIntelligenceMeetingMinutesGenerator.engineName
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedMinutesItem {
    var text: String
    var sourceSeconds: Int?

    var domainValue: MeetingMinutesItem? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return MeetingMinutesItem(
            text: cleaned,
            sourceTime: sourceSeconds.map { TimeInterval(max(0, $0)) }
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedActionItem {
    var task: String
    var assignee: String?
    var deadline: String?
    var sourceSeconds: Int?

    var domainValue: MeetingActionItem? {
        let cleanedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTask.isEmpty else { return nil }

        return MeetingActionItem(
            task: cleanedTask,
            assignee: assignee?.nilIfBlank,
            deadline: deadline?.nilIfBlank,
            sourceTime: sourceSeconds.map { TimeInterval(max(0, $0)) }
        )
    }
}
#endif

private extension Array where Element == String {
    var cleanedStrings: [String] {
        compactMap(\.nilIfBlank)
    }
}

private extension String {
    var nilIfBlank: String? {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
