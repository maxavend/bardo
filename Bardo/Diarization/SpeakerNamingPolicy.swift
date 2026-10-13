import Foundation

enum SpeakerNamingPresentation: Equatable, Sendable {
    case identifySpeakers
    case singleSpeaker
    case participants(Int)
}

enum SpeakerNamingPolicy {
    static func presentation(for transcript: Transcript) -> SpeakerNamingPresentation {
        // Tracks transcribed apart already separate "You" from "Others"; the others are
        // still one voice until their participants are told apart.
        if transcript.diarizationMetadata == nil, transcript.speakers.contains(where: { $0.role == .others }) {
            return .identifySpeakers
        }
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
