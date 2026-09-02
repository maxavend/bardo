import Foundation

enum SpeakerNamingPresentation: Equatable, Sendable {
    case identifySpeakers
    case singleSpeaker
    case participants(Int)
}

enum SpeakerNamingPolicy {
    static func presentation(for transcript: Transcript) -> SpeakerNamingPresentation {
        switch transcript.speakers.count {
        case 0:
            return .identifySpeakers
        case 1:
            return .singleSpeaker
        default:
            return .participants(transcript.speakers.count)
        }
    }

    static func shouldOpenNamingFlow(after transcript: Transcript) -> Bool {
        transcript.speakers.count >= 2
    }
}
