import Foundation

enum QwenMeetingMinutesResponseParser {
    enum ParserError: Error, LocalizedError, Equatable {
        case missingJSONObject
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .missingJSONObject:
                return "The local model did not return a meeting-minutes object."
            case .invalidJSON(let reason):
                return "The local model returned invalid meeting-minutes JSON: \(reason)"
            }
        }
    }

    static func parse(_ response: String, recordingID: Recording.ID) throws -> MeetingMinutes {
        let object = try extractJSONObject(from: response)

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(object.utf8))
        } catch {
            throw ParserError.invalidJSON(error.localizedDescription)
        }

        return MeetingMinutes(
            recordingID: recordingID,
            summary: payload.summary.trimmed,
            topics: payload.topics.compactMap(\.nonEmptyTrimmed),
            decisions: payload.decisions.compactMap(\.domainValue),
            actionItems: payload.actionItems.compactMap(\.domainValue),
            openQuestions: payload.openQuestions.compactMap(\.domainValue),
            engine: QwenMeetingMinutesGenerator.engineName
        )
    }

    private static func extractJSONObject(from response: String) throws -> String {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end else {
            throw ParserError.missingJSONObject
        }

        return String(response[start...end])
    }
}

private extension QwenMeetingMinutesResponseParser {
    struct Payload: Decodable {
        let summary: String
        let topics: [String]
        let decisions: [Item]
        let actionItems: [ActionItem]
        let openQuestions: [Item]

        enum CodingKeys: String, CodingKey {
            case summary
            case topics
            case decisions
            case actionItems
            case openQuestions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
            decisions = try container.decodeIfPresent([Item].self, forKey: .decisions) ?? []
            actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
            openQuestions = try container.decodeIfPresent([Item].self, forKey: .openQuestions) ?? []
        }
    }

    struct Item: Decodable {
        let text: String
        let sourceSeconds: Int?

        var domainValue: MeetingMinutesItem? {
            guard let text = text.nonEmptyTrimmed else { return nil }
            return MeetingMinutesItem(
                text: text,
                sourceTime: sourceSeconds.map { TimeInterval(max(0, $0)) }
            )
        }
    }

    struct ActionItem: Decodable {
        let task: String
        let assignee: String?
        let deadline: String?
        let sourceSeconds: Int?

        var domainValue: MeetingActionItem? {
            guard let task = task.nonEmptyTrimmed else { return nil }
            return MeetingActionItem(
                task: task,
                assignee: assignee?.nonEmptyTrimmed,
                deadline: deadline?.nonEmptyTrimmed,
                sourceTime: sourceSeconds.map { TimeInterval(max(0, $0)) }
            )
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nonEmptyTrimmed: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
