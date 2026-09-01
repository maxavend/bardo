import Foundation

enum SpeakerNamingPolicy {
    static func shouldPrompt(speakerCount: Int) -> Bool {
        speakerCount >= 2
    }
}
