import Foundation

enum MeetingEvidenceType: String, Codable, CaseIterable, Sendable {
    case fact
    case context
    case proposal
    case preference
    case hypothesis
    case decision
    case agreement
    case pending
    case openQuestion
    case risk
    case nextStep
}

enum MeetingEvidenceCertainty: String, Codable, Sendable {
    case explicit
    case qualified
    case unresolved
}

struct MeetingEvidence: Codable, Equatable, Sendable {
    let type: MeetingEvidenceType
    let topic: String
    let statement: String
    let rationale: String?
    let responsible: String?
    let validator: String?
    let certainty: MeetingEvidenceCertainty
    let sourceSegmentIDs: [UUID]
    let startTime: TimeInterval?
    let endTime: TimeInterval?

    init(
        type: MeetingEvidenceType,
        topic: String,
        statement: String,
        rationale: String? = nil,
        responsible: String? = nil,
        validator: String? = nil,
        certainty: MeetingEvidenceCertainty = .explicit,
        sourceSegmentIDs: [UUID] = [],
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.type = type
        self.topic = topic
        self.statement = statement
        self.rationale = rationale
        self.responsible = responsible
        self.validator = validator
        self.certainty = certainty
        self.sourceSegmentIDs = sourceSegmentIDs
        self.startTime = startTime
        self.endTime = endTime
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case topic
        case statement
        case rationale
        case responsible
        case validator
        case certainty
        case sourceSegmentIDs
        case startTime
        case endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(MeetingEvidenceType.self, forKey: .type) ?? .context
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        statement = try container.decodeIfPresent(String.self, forKey: .statement) ?? ""
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        responsible = try container.decodeIfPresent(String.self, forKey: .responsible)
        validator = try container.decodeIfPresent(String.self, forKey: .validator)
        certainty = try container.decodeIfPresent(MeetingEvidenceCertainty.self, forKey: .certainty) ?? .qualified
        sourceSegmentIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceSegmentIDs) ?? []
        startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
    }
}

struct MeetingTopicAnalysis: Codable, Equatable, Sendable {
    let title: String
    let context: String?
    let criteria: [String]
    let evidence: [MeetingEvidence]
    let decisions: [String]
    let pending: [String]

    init(
        title: String,
        context: String? = nil,
        criteria: [String] = [],
        evidence: [MeetingEvidence] = [],
        decisions: [String] = [],
        pending: [String] = []
    ) {
        self.title = title
        self.context = context
        self.criteria = criteria
        self.evidence = evidence
        self.decisions = decisions
        self.pending = pending
    }
}

struct MeetingFollowUp: Codable, Equatable, Sendable {
    let statement: String
    let responsible: String?
    let validator: String?
    let sourceSegmentIDs: [UUID]

    init(
        statement: String,
        responsible: String? = nil,
        validator: String? = nil,
        sourceSegmentIDs: [UUID] = []
    ) {
        self.statement = statement
        self.responsible = responsible
        self.validator = validator
        self.sourceSegmentIDs = sourceSegmentIDs
    }
}

struct MeetingAnalysis: Codable, Equatable, Sendable {
    let summary: String?
    let topics: [MeetingTopicAnalysis]
    let agreements: [String]
    let pending: [MeetingFollowUp]
    let risks: [String]
    let nextSteps: [MeetingFollowUp]
    let conclusion: String?

    init(
        summary: String? = nil,
        topics: [MeetingTopicAnalysis] = [],
        agreements: [String] = [],
        pending: [MeetingFollowUp] = [],
        risks: [String] = [],
        nextSteps: [MeetingFollowUp] = [],
        conclusion: String? = nil
    ) {
        self.summary = summary
        self.topics = topics
        self.agreements = agreements
        self.pending = pending
        self.risks = risks
        self.nextSteps = nextSteps
        self.conclusion = conclusion
    }
}

enum MeetingMinutesEvidenceReducer {
    static func reduce(_ evidence: [MeetingEvidence]) -> [MeetingEvidence] {
        var reduced = [MeetingEvidence]()
        var indexes = [String: Int]()
        let ordered = evidence
            .filter { !$0.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsTime = lhs.startTime ?? .greatestFiniteMagnitude
                let rhsTime = rhs.startTime ?? .greatestFiniteMagnitude
                if lhsTime != rhsTime { return lhsTime < rhsTime }
                return identityKey(lhs) < identityKey(rhs)
            }

        for item in ordered {
            let key = identityKey(item)
            if let index = indexes[key] {
                reduced[index] = merge(reduced[index], with: item)
            } else {
                indexes[key] = reduced.count
                reduced.append(item)
            }
        }
        return reduced
    }

    static func fallbackAnalysis(from evidence: [MeetingEvidence]) -> MeetingAnalysis {
        let grouped = Dictionary(grouping: evidence) { item in
            let value = item.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "General discussion" : value
        }
        let topics = grouped.keys.sorted().map { title in
            let items = grouped[title, default: []]
            return MeetingTopicAnalysis(
                title: title,
                evidence: items,
                decisions: items.filter { $0.type == .decision || $0.type == .agreement }.map(\.statement),
                pending: items.filter { $0.type == .pending || $0.type == .openQuestion }.map(\.statement)
            )
        }
        let followUps = evidence
            .filter { $0.type == .pending || $0.type == .openQuestion }
            .map { MeetingFollowUp(statement: $0.statement, validator: $0.validator, sourceSegmentIDs: $0.sourceSegmentIDs) }
        let nextSteps = evidence
            .filter { $0.type == .nextStep }
            .map { MeetingFollowUp(statement: $0.statement, responsible: $0.responsible, validator: $0.validator, sourceSegmentIDs: $0.sourceSegmentIDs) }
        return MeetingAnalysis(
            topics: topics,
            agreements: evidence.filter { $0.type == .agreement }.map(\.statement),
            pending: followUps,
            risks: evidence.filter { $0.type == .risk }.map(\.statement),
            nextSteps: nextSteps
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func identityKey(_ item: MeetingEvidence) -> String {
        [item.type.rawValue, normalized(item.topic), normalized(item.statement)].joined(separator: "|")
    }

    private static func merge(_ lhs: MeetingEvidence, with rhs: MeetingEvidence) -> MeetingEvidence {
        var sourceIDs = lhs.sourceSegmentIDs
        for sourceID in rhs.sourceSegmentIDs where !sourceIDs.contains(sourceID) {
            sourceIDs.append(sourceID)
        }
        return MeetingEvidence(
            type: lhs.type,
            topic: lhs.topic.isEmpty ? rhs.topic : lhs.topic,
            statement: lhs.statement,
            rationale: lhs.rationale ?? rhs.rationale,
            responsible: mergedValue(lhs.responsible, rhs.responsible),
            validator: mergedValue(lhs.validator, rhs.validator),
            certainty: moreConservative(lhs.certainty, rhs.certainty),
            sourceSegmentIDs: sourceIDs,
            startTime: minTime(lhs.startTime, rhs.startTime),
            endTime: maxTime(lhs.endTime, rhs.endTime)
        )
    }

    private static func mergedValue(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs, let rhs else { return lhs ?? rhs }
        return normalized(lhs) == normalized(rhs) ? lhs : nil
    }

    private static func moreConservative(
        _ lhs: MeetingEvidenceCertainty,
        _ rhs: MeetingEvidenceCertainty
    ) -> MeetingEvidenceCertainty {
        func rank(_ certainty: MeetingEvidenceCertainty) -> Int {
            switch certainty {
            case .explicit: return 0
            case .qualified: return 1
            case .unresolved: return 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func minTime(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return min(lhs, rhs)
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }

    private static func maxTime(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }
}
