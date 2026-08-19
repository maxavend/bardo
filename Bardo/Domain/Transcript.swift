import Foundation

struct Speaker: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String?

    init(id: UUID = UUID(), name: String? = nil) {
        self.id = id
        self.name = name
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    var speakerID: Speaker.ID?
    var text: String

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: Speaker.ID? = nil,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.text = text
    }
}

struct Transcript: Codable, Equatable, Sendable {
    let recordingID: Recording.ID
    var languageCode: String?
    var speakers: [Speaker]
    var segments: [TranscriptSegment]

    init(
        recordingID: Recording.ID,
        languageCode: String? = nil,
        speakers: [Speaker] = [],
        segments: [TranscriptSegment] = []
    ) {
        self.recordingID = recordingID
        self.languageCode = languageCode
        self.speakers = speakers
        self.segments = segments
    }
}
