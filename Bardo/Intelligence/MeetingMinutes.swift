import Foundation

struct MeetingMinutes: Codable, Equatable, Sendable {
    let recordingID: Recording.ID
    let summary: String
    let topics: [String]
    let decisions: [MeetingMinutesItem]
    let actionItems: [MeetingActionItem]
    let openQuestions: [MeetingMinutesItem]
    let generatedAt: Date
    let engine: String

    init(
        recordingID: Recording.ID,
        summary: String,
        topics: [String] = [],
        decisions: [MeetingMinutesItem] = [],
        actionItems: [MeetingActionItem] = [],
        openQuestions: [MeetingMinutesItem] = [],
        generatedAt: Date = Date(),
        engine: String
    ) {
        self.recordingID = recordingID
        self.summary = summary
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.generatedAt = generatedAt
        self.engine = engine
    }
}

struct MeetingMinutesItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let sourceTime: TimeInterval?

    init(id: UUID = UUID(), text: String, sourceTime: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.sourceTime = sourceTime
    }
}

struct MeetingActionItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let task: String
    let assignee: String?
    let deadline: String?
    let sourceTime: TimeInterval?

    init(
        id: UUID = UUID(),
        task: String,
        assignee: String? = nil,
        deadline: String? = nil,
        sourceTime: TimeInterval? = nil
    ) {
        self.id = id
        self.task = task
        self.assignee = assignee
        self.deadline = deadline
        self.sourceTime = sourceTime
    }
}

enum MeetingMinutesAvailability: Equatable, Sendable {
    case available
    case requiresNewerMacOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    var isAvailable: Bool {
        self == .available
    }

    var message: String {
        switch self {
        case .available:
            return "Apple Intelligence is ready."
        case .requiresNewerMacOS:
            return "Meeting minutes with Apple Intelligence require a newer version of macOS."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to generate meeting minutes."
        case .modelNotReady:
            return "Apple Intelligence is still preparing its on-device model. Try again when the model is ready."
        }
    }
}

enum MeetingMinutesGenerationError: Error, LocalizedError, Equatable, Sendable {
    case emptyTranscript
    case unavailable(MeetingMinutesAvailability)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "There is no transcript to summarize."
        case .unavailable(let availability):
            return availability.message
        }
    }
}
